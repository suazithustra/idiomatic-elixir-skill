defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths to handlers.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0`
  > and `match/1` in your module. Each `get/2` call is checked when the
  > module compiles.

  Segments that start with `:` capture the matching part of the path into
  the params map, under the atom after the colon.

  ## Example

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{id: "42"}}
  """

  @doc """
  Declares a route from `path` to `handler`.

  `path` must be a string literal and `handler` must be a module name.
  """
  defmacro get(path, handler) do
    path = validate_path!(path, __CALLER__)
    handler = validate_handler!(handler, __CALLER__)

    quote do
      @tiny_router_routes {unquote(path), unquote(handler)}
    end
  end

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    compiled = for {path, handler} <- routes, do: {compile_path(path), handler}

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc "Returns `{:ok, handler, params}` for the first matching route, or `:error`."
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path), do: TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
    end
  end

  @doc false
  @spec __match__([{[{:static | :param, String.t() | atom()}], module()}], String.t()) ::
          {:ok, module(), %{atom() => String.t()}} | :error
  def __match__(compiled, path) when is_binary(path) do
    segments = String.split(path, "/", trim: true)

    Enum.find_value(compiled, :error, fn {pattern, handler} ->
      case match_segments(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp validate_path!(path, _env) when is_binary(path), do: path

  defp validate_path!(path, env) do
    raise CompileError,
      file: env.file,
      line: env.line,
      description: "get/2 expects the path to be a string, got: #{Macro.to_string(path)}"
  end

  defp validate_handler!(handler, env) do
    case Macro.expand(handler, env) do
      module when is_atom(module) and module not in [nil, true, false] ->
        module

      _other ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description:
            "get/2 expects the handler to be a module name, got: #{Macro.to_string(handler)}"
    end
  end

  defp compile_path(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(fn
      ":" <> name -> {:param, String.to_atom(name)}
      segment -> {:static, segment}
    end)
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:static, same} | pattern], [same | segments], params) do
    match_segments(pattern, segments, params)
  end

  defp match_segments([{:param, name} | pattern], [value | segments], params) do
    match_segments(pattern, segments, Map.put(params, name, value))
  end

  defp match_segments(_pattern, _segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
