defmodule TinyRouter do
  @moduledoc """
  A small routing DSL.

  Add `use TinyRouter` to a module, then declare routes with `get/2`.
  The module gets `routes/0` (declared `{path, handler}` pairs, in order)
  and `match/1` (looks up a request path).

  Path and handler are checked when the module compiles.
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  defmacro get(path, handler) do
    path = Macro.expand(path, __CALLER__)
    handler = Macro.expand(handler, __CALLER__)

    unless is_binary(path) do
      raise_compile_error!(__CALLER__, "get/2 expects a string path, got: #{Macro.to_string(path)}")
    end

    unless module_name?(handler) do
      raise_compile_error!(
        __CALLER__,
        "get/2 expects a module name as handler, got: #{Macro.to_string(handler)}"
      )
    end

    quote do
      @tiny_router_routes {unquote(path), unquote(handler)}
    end
  end

  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    compiled = Enum.map(routes, fn {path, handler} -> {path, handler, compile_path(path)} end)

    quote do
      def routes, do: unquote(Macro.escape(routes))

      def match(path) when is_binary(path) do
        TinyRouter.lookup(unquote(Macro.escape(compiled)), path)
      end

      def match(_path), do: :error
    end
  end

  @doc false
  def lookup(compiled_routes, path) do
    segments = split(path)

    Enum.find_value(compiled_routes, :error, fn {_path, handler, pattern} ->
      case bind(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp compile_path(path) do
    path
    |> split()
    |> Enum.map(fn
      ":" <> name when name != "" -> {:param, String.to_atom(name)}
      segment -> {:static, segment}
    end)
  end

  defp split(path), do: String.split(path, "/", trim: true)

  defp bind([], [], params), do: {:ok, params}

  defp bind([{:static, segment} | pattern], [segment | segments], params) do
    bind(pattern, segments, params)
  end

  defp bind([{:param, name} | pattern], [value | segments], params) do
    bind(pattern, segments, Map.put(params, name, value))
  end

  defp bind(_pattern, _segments, _params), do: :error

  defp module_name?(atom) when is_atom(atom) do
    String.starts_with?(Atom.to_string(atom), "Elixir.")
  end

  defp module_name?(_), do: false

  defp raise_compile_error!(caller, description) do
    raise CompileError, file: caller.file, line: caller.line, description: description
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
