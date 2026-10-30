defmodule TinyRouter do
  @moduledoc """
  Declares request routes in a module and matches request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and, when the module
  > compiles, defines `routes/0` and `match/1`.

  ## Example

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

  Paths must be string literals and handlers must be module names. Any other
  value fails when the module compiles.
  """

  @doc """
  Declares a route from `path` to `handler`.

  Routes keep their declaration order. A `:name` segment in the path captures
  the matching part of a request path under `:name` in the params.

  Raises `CompileError` when `path` is not a string literal or `handler` is
  not a module name.
  """
  defmacro get(path, handler) do
    route = __route__(__CALLER__, path, handler)

    quote do
      @tiny_router_routes unquote(route)
    end
  end

  @doc false
  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)

      @before_compile TinyRouter
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = Enum.reverse(Module.get_attribute(env.module, :tiny_router_routes))
    compiled = Enum.map(routes, fn {path, handler} -> {parse_segments(path), handler} end)

    quote do
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @spec match(String.t()) :: {:ok, module(), map()} | :error
      def match(path), do: TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
    end
  end

  @doc false
  def __route__(caller, path, handler) do
    {validate_path!(caller, path), validate_handler!(caller, handler)}
  end

  @doc false
  def __match__(routes, path) when is_binary(path) do
    segments = split_path(path)

    Enum.find_value(routes, :error, &match_route(&1, segments))
  end

  defp match_route({pattern, handler}, segments) do
    case bind_segments(pattern, segments, %{}) do
      {:ok, params} -> {:ok, handler, params}
      :error -> nil
    end
  end

  defp bind_segments([], [], params), do: {:ok, params}

  defp bind_segments([{:param, key} | pattern], [value | segments], params) do
    bind_segments(pattern, segments, Map.put(params, key, value))
  end

  defp bind_segments([{:static, text} | pattern], [text | segments], params) do
    bind_segments(pattern, segments, params)
  end

  defp bind_segments(_pattern, _segments, _params), do: :error

  defp parse_segments(path) do
    path
    |> split_path()
    |> Enum.map(&parse_segment/1)
  end

  defp parse_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp parse_segment(segment), do: {:static, segment}

  defp split_path(path), do: String.split(path, "/", trim: true)

  defp validate_path!(_caller, path) when is_binary(path), do: path

  defp validate_path!(caller, path) do
    compile_error!(caller, "route path must be a string literal, got #{Macro.to_string(path)}")
  end

  defp validate_handler!(caller, handler) do
    expanded = Macro.expand(handler, caller)

    if is_atom(expanded) and expanded not in [nil, true, false] do
      expanded
    else
      detail = Macro.to_string(handler)
      compile_error!(caller, "route handler must be a module name, got #{detail}")
    end
  end

  defp compile_error!(caller, description) do
    raise CompileError, file: caller.file, line: caller.line, description: description
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
