defmodule TinyRouter do
  @moduledoc """
  A small router DSL. A module that calls `use TinyRouter` declares routes
  with `get/2`. Route paths and handlers are checked when the module compiles.

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

  The module then exposes `routes/0` and `match/1`.
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route. `path` must be a string literal. `handler` must be a module name.
  """
  defmacro get(path, handler) do
    caller = __CALLER__
    path_value = Macro.expand(path, caller)
    handler_value = Macro.expand(handler, caller)

    unless is_binary(path_value) do
      compile_error!(caller, "route path must be a string, got: #{Macro.to_string(path)}")
    end

    unless is_atom(handler_value) and module_name?(handler_value) do
      compile_error!(caller, "route handler must be a module name, got: #{Macro.to_string(handler)}")
    end

    segments = parse_segments!(path_value, caller)

    quote do
      @tiny_router_routes {unquote(path_value), unquote(handler_value), unquote(Macro.escape(segments))}
    end
  end

  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    public = Enum.map(routes, fn {path, handler, _segments} -> {path, handler} end)
    compiled = Enum.map(routes, fn {_path, handler, segments} -> {handler, segments} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      def routes, do: unquote(Macro.escape(public))

      @doc "Matches a request path. Returns `{:ok, handler, params}` or `:error`."
      def match(path) when is_binary(path) do
        segments = TinyRouter.split_path(path)

        Enum.find_value(unquote(Macro.escape(compiled)), :error, fn {handler, pattern} ->
          case TinyRouter.bind(pattern, segments) do
            {:ok, params} -> {:ok, handler, params}
            :error -> nil
          end
        end)
      end
    end
  end

  @doc false
  def split_path(path), do: String.split(path, "/", trim: true)

  @doc false
  def bind(pattern, segments), do: bind(pattern, segments, %{})

  defp bind([], [], params), do: {:ok, params}

  defp bind([{:static, same} | pattern], [same | segments], params),
    do: bind(pattern, segments, params)

  defp bind([{:param, name} | pattern], [value | segments], params),
    do: bind(pattern, segments, Map.put(params, name, value))

  defp bind(_, _, _), do: :error

  defp parse_segments!(path, caller) do
    path
    |> split_path()
    |> Enum.map(fn
      ":" <> "" -> compile_error!(caller, "route #{inspect(path)} has a parameter with no name")
      ":" <> name -> {:param, String.to_atom(name)}
      segment -> {:static, segment}
    end)
  end

  defp module_name?(atom), do: String.starts_with?(Atom.to_string(atom), "Elixir.")

  defp compile_error!(caller, message) do
    raise CompileError, file: caller.file, line: caller.line, description: message
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
