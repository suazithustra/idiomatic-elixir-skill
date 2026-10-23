defmodule TinyRouter do
  @moduledoc """
  Declarative routing for a module.

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

  Routes are checked when the router module compiles.
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  defmacro get(path, handler) do
    caller = __CALLER__
    expanded_path = Macro.expand(path, caller)
    expanded_handler = Macro.expand(handler, caller)

    unless is_binary(expanded_path) do
      compile_error!(caller, "route path must be a string, got: #{Macro.to_string(path)}")
    end

    unless module_name?(expanded_handler) do
      compile_error!(caller, "route handler must be a module name, got: #{Macro.to_string(handler)}")
    end

    quote do
      @tiny_routes {unquote(expanded_path), unquote(expanded_handler)}
    end
  end

  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_routes) |> Enum.reverse()
    compiled = Enum.map(routes, fn {path, handler} -> {split(path), handler} end)

    quote do
      def routes, do: unquote(Macro.escape(routes))

      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
      end
    end
  end

  @doc false
  def __match__(compiled, path) do
    segments = split(path)

    Enum.find_value(compiled, :error, fn {pattern, handler} ->
      case bind(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  @doc false
  def split(path), do: String.split(path, "/", trim: true)

  defp bind([], [], params), do: {:ok, params}

  defp bind([":" <> name | pattern], [segment | segments], params) do
    bind(pattern, segments, Map.put(params, name, segment))
  end

  defp bind([literal | pattern], [literal | segments], params), do: bind(pattern, segments, params)

  defp bind(_pattern, _segments, _params), do: :error

  defp module_name?(value), do: is_atom(value) and value not in [nil, true, false]

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
