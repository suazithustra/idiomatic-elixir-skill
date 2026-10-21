defmodule TinyRouter do
  @moduledoc """
  Declares a list of path-to-handler routes in a module.

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.routes()
      #=> [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{id: "42"}}

  Paths and handlers are checked when the router compiles. Bad input
  raises a `CompileError` that points at the offending `get` line.
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
    caller = __CALLER__
    expanded_path = Macro.expand(path, caller)
    expanded_handler = Macro.expand(handler, caller)

    unless is_binary(expanded_path) do
      compile_error!(caller, "path must be a string, got: #{Macro.to_string(path)}")
    end

    unless is_atom(expanded_handler) and expanded_handler not in [nil, true, false] do
      compile_error!(caller, "handler must be a module name, got: #{Macro.to_string(handler)}")
    end

    validate_path!(expanded_path, caller)

    quote do
      @tiny_router_routes {unquote(expanded_path), unquote(expanded_handler)}
    end
  end

  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    compiled = Enum.map(routes, fn {path, handler} -> {parse_path(path), handler} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs, in declaration order."
      def routes, do: unquote(Macro.escape(routes))

      @doc "Finds the handler for a request path. Returns `{:ok, handler, params}` or `:error`."
      def match(path) when is_binary(path) do
        segments = TinyRouter.split(path)

        Enum.find_value(unquote(Macro.escape(compiled)), :error, fn {pattern, handler} ->
          case TinyRouter.match_segments(pattern, segments, %{}) do
            {:ok, params} -> {:ok, handler, params}
            :error -> nil
          end
        end)
      end
    end
  end

  @doc false
  def split(path), do: String.split(path, "/", trim: true)

  @doc false
  def match_segments([], [], params), do: {:ok, params}

  def match_segments([{:literal, same} | pattern], [same | segments], params) do
    match_segments(pattern, segments, params)
  end

  def match_segments([{:param, name} | pattern], [value | segments], params) do
    match_segments(pattern, segments, Map.put(params, name, value))
  end

  def match_segments(_pattern, _segments, _params), do: :error

  defp parse_path(path) do
    Enum.map(split(path), fn
      ":" <> name -> {:param, String.to_atom(name)}
      segment -> {:literal, segment}
    end)
  end

  defp validate_path!(path, caller) do
    Enum.each(split(path), fn
      ":" -> compile_error!(caller, "path #{inspect(path)} has a parameter with no name")
      _segment -> :ok
    end)
  end

  defp compile_error!(caller, message) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "TinyRouter: " <> message
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
