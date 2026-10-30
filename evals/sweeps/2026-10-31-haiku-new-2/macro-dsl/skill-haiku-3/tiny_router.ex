defmodule TinyRouter do
  @moduledoc """
  Declares path routes in a module and matches request paths to handlers.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0` and
  > `match/1` in your module. Routes are checked when the module compiles.

  ## Example

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{id: "42"}}
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route.

  `path` must be a string literal. `handler` must be a module name written
  as a literal, such as `MyApp.PageHandler`. Segments that start with `:`
  capture a value into `params`.
  """
  defmacro get(path, handler) do
    path = expand_path!(path, __CALLER__)
    handler = expand_handler!(handler, __CALLER__)

    quote do
      TinyRouter.__put_route__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  @spec __put_route__(module(), String.t(), module()) :: :ok
  def __put_route__(module, path, handler) do
    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  @doc false
  @spec __match__([{[segment], module()}], String.t()) :: {:ok, module(), map()} | :error
        when segment: {:static, String.t()} | {:param, atom()}
  def __match__(routes, path) do
    segments = split_path(path)

    Enum.find_value(routes, :error, fn {pattern, handler} ->
      case match_segments(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    compiled = Enum.map(routes, fn {path, handler} -> {parse_segments(path), handler} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc "Returns `{:ok, handler, params}` for the first route that matches `path`, or `:error`."
      @spec match(String.t()) :: {:ok, module(), map()} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
      end
    end
  end

  defp expand_path!(path, caller) do
    case Macro.expand(path, caller) do
      path when is_binary(path) ->
        path

      other ->
        compile_error!(caller, "route path must be a string, got: #{Macro.to_string(other)}")
    end
  end

  defp expand_handler!(handler, caller) do
    case Macro.expand(handler, caller) do
      module when is_atom(module) and module not in [nil, true, false] ->
        module

      other ->
        description = "route handler must be a module name, got: #{Macro.to_string(other)}"
        compile_error!(caller, description)
    end
  end

  defp compile_error!(caller, description) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "invalid TinyRouter route in #{inspect(caller.module)}: #{description}"
  end

  defp parse_segments(path) do
    for segment <- split_path(path) do
      case segment do
        ":" <> name -> {:param, String.to_atom(name)}
        static -> {:static, static}
      end
    end
  end

  defp split_path(path), do: String.split(path, "/", trim: true)

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:static, text} | pattern], [text | segments], params) do
    match_segments(pattern, segments, params)
  end

  defp match_segments([{:param, name} | pattern], [value | segments], params) do
    match_segments(pattern, segments, Map.put(params, name, value))
  end

  defp match_segments(_pattern, _segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
