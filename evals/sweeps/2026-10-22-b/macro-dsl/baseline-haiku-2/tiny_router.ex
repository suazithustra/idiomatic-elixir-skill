defmodule TinyRouter do
  @moduledoc """
  Declares routes with a small DSL.

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

  Paths must be string literals and handlers must be module names. Both are
  checked when the router module compiles.
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route from `path` to the `handler` module.
  """
  defmacro get(path, handler) do
    path = expand_path!(path, __CALLER__)
    handler = expand_handler!(handler, __CALLER__)

    quote do
      @tiny_router_routes {unquote(path), unquote(handler)}
    end
  end

  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    compiled = Enum.map(routes, fn {path, handler} -> {compile_pattern(path), handler} end)

    quote do
      def routes, do: unquote(Macro.escape(routes))

      def match(path), do: TinyRouter.dispatch(unquote(Macro.escape(compiled)), path)
    end
  end

  @doc false
  def dispatch(compiled, path) do
    segments = split(path)

    Enum.find_value(compiled, :error, fn {pattern, handler} ->
      case bind(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp bind([], [], params), do: {:ok, params}

  defp bind([{:param, key} | pattern], [segment | segments], params),
    do: bind(pattern, segments, Map.put(params, key, segment))

  defp bind([{:literal, literal} | pattern], [literal | segments], params),
    do: bind(pattern, segments, params)

  defp bind(_pattern, _segments, _params), do: :error

  defp compile_pattern(path) do
    for segment <- split(path) do
      case segment do
        ":" <> name -> {:param, String.to_atom(name)}
        literal -> {:literal, literal}
      end
    end
  end

  defp split(path), do: String.split(path, "/", trim: true)

  defp expand_path!(path, caller) do
    if is_binary(path) do
      path
    else
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description: "TinyRouter expects a string path, got: #{Macro.to_string(path)}"
    end
  end

  defp expand_handler!(handler, caller) do
    case Macro.expand(handler, caller) do
      module when is_atom(module) and module not in [nil, true, false] ->
        module

      _ ->
        raise CompileError,
          file: caller.file,
          line: caller.line,
          description: "TinyRouter expects a module name as handler, got: #{Macro.to_string(handler)}"
    end
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
