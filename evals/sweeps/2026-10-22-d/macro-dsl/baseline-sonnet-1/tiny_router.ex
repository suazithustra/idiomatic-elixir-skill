defmodule TinyRouter do
  @moduledoc """
  A tiny compile-time route DSL.

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.routes()
      #=> [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{"id" => "42"}}

  Routes are tried in declaration order; the first match wins.
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route. `path` must be a string literal and `handler` a module name.
  """
  defmacro get(path, handler) do
    handler = Macro.expand(handler, __CALLER__)

    unless is_binary(path) do
      compile_error!(
        __CALLER__,
        "get/2 expects the path to be a string, got: #{Macro.to_string(path)}"
      )
    end

    unless is_atom(handler) and handler not in [nil, true, false] do
      compile_error!(
        __CALLER__,
        "get/2 expects the handler to be a module name, got: #{Macro.to_string(handler)}"
      )
    end

    segments = compile_segments!(path, __CALLER__)

    quote do
      @tiny_router_routes {unquote(path), unquote(handler), unquote(Macro.escape(segments))}
    end
  end

  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    pairs = for {path, handler, _segments} <- routes, do: {path, handler}
    compiled = for {_path, handler, segments} <- routes, do: {segments, handler}

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(pairs))

      @doc "Matches a request path against the declared routes."
      @spec match(String.t()) :: {:ok, module(), %{optional(String.t()) => String.t()}} | :error
      def match(path) when is_binary(path) do
        TinyRouter.match_route(unquote(Macro.escape(compiled)), TinyRouter.split(path))
      end

      def match(_path), do: :error
    end
  end

  @doc false
  def split(path), do: String.split(path, "/", trim: true)

  @doc false
  def match_route([], _segments), do: :error

  def match_route([{pattern, handler} | rest], segments) do
    case match_segments(pattern, segments, %{}) do
      {:ok, params} -> {:ok, handler, params}
      :error -> match_route(rest, segments)
    end
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, name} | pattern], [value | segments], params),
    do: match_segments(pattern, segments, Map.put(params, name, value))

  defp match_segments([{:literal, segment} | pattern], [segment | segments], params),
    do: match_segments(pattern, segments, params)

  defp match_segments(_pattern, _segments, _params), do: :error

  defp compile_segments!(path, caller) do
    unless String.starts_with?(path, "/") do
      compile_error!(caller, "get/2 expects the path to start with \"/\", got: #{inspect(path)}")
    end

    for segment <- split(path) do
      case segment do
        ":" -> compile_error!(caller, "get/2 found a parameter with no name in #{inspect(path)}")
        ":" <> name -> {:param, name}
        literal -> {:literal, literal}
      end
    end
  end

  defp compile_error!(caller, message) do
    raise CompileError, file: caller.file, line: caller.line, description: message
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
