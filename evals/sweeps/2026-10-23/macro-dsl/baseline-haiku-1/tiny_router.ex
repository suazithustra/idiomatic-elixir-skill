defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module with `get/2` and matches request paths against them.

  Paths must be string literals. Handlers must be module names. Both are
  checked when the router module compiles.

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

  defmacro get(path, handler) do
    path = validate_path!(path, __CALLER__)
    handler = validate_handler!(handler, __CALLER__)

    quote do
      @tiny_router_routes {unquote(path), unquote(handler)}
    end
  end

  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(:tiny_router_routes)
      |> Enum.reverse()

    compiled =
      Enum.map(routes, fn {path, handler} -> {parse_pattern(path), handler} end)

    quote do
      def routes, do: unquote(Macro.escape(routes))

      def match(path) when is_binary(path) do
        TinyRouter.match_compiled(path, unquote(Macro.escape(compiled)))
      end
    end
  end

  @doc false
  def match_compiled(path, compiled) do
    segments = split(path)

    Enum.find_value(compiled, :error, fn {pattern, handler} ->
      case bind(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp validate_path!(path, _env) when is_binary(path), do: path

  defp validate_path!(_other, env) do
    raise CompileError,
      file: env.file,
      line: env.line,
      description: "TinyRouter: the path in get/2 must be a string literal, e.g. get \"/users/:id\", Handler"
  end

  defp validate_handler!(handler, env) do
    case Macro.expand(handler, env) do
      atom when is_atom(atom) and atom not in [nil, true, false] ->
        atom

      _ ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description: "TinyRouter: the handler in get/2 must be a module name, e.g. get \"/\", MyApp.PageHandler"
    end
  end

  defp parse_pattern(path) do
    path
    |> split()
    |> Enum.map(fn
      ":" <> name -> {:param, String.to_atom(name)}
      segment -> segment
    end)
  end

  defp split(path), do: String.split(path, "/", trim: true)

  defp bind([], [], params), do: {:ok, params}

  defp bind([{:param, name} | pattern], [segment | segments], params),
    do: bind(pattern, segments, Map.put(params, name, segment))

  defp bind([literal | pattern], [literal | segments], params),
    do: bind(pattern, segments, params)

  defp bind(_pattern, _segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
