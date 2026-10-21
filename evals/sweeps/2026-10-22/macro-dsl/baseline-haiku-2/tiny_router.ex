defmodule TinyRouter do
  @moduledoc """
  A small router DSL. A module that calls `use TinyRouter` declares routes
  with `get/2`. The module then gets `routes/0` and `match/1`.

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route. `path` must be a string literal. `handler` must be a
  module name such as `MyApp.PageHandler`.
  """
  defmacro get(path, handler) do
    check_path!(path, __CALLER__)
    handler = check_handler!(handler, __CALLER__)

    quote do
      @tiny_router_routes {unquote(path), unquote(handler)}
    end
  end

  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(:tiny_router_routes)
      |> Enum.reverse()

    compiled = Enum.map(routes, fn {path, handler} -> {compile_path(path), handler} end)

    quote do
      def routes, do: unquote(Macro.escape(routes))

      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
      end
    end
  end

  @doc false
  def __match__(routes, path) do
    segments = split(path)

    Enum.find_value(routes, :error, fn {pattern, handler} ->
      case bind(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp check_path!(path, _caller) when is_binary(path), do: path

  defp check_path!(path, caller) do
    raise CompileError,
      description:
        "route path must be a string literal like \"/users/:id\", got: " <>
          Macro.to_string(path),
      file: caller.file,
      line: caller.line
  end

  defp check_handler!(handler, caller) do
    expanded = Macro.expand(handler, caller)

    if is_atom(expanded) and String.starts_with?(Atom.to_string(expanded), "Elixir.") do
      expanded
    else
      raise CompileError,
        description:
          "route handler must be a module name like MyApp.PageHandler, got: " <>
            Macro.to_string(handler),
        file: caller.file,
        line: caller.line
    end
  end

  defp compile_path(path) do
    path
    |> split()
    |> Enum.map(fn
      ":" <> name -> {:param, String.to_atom(name)}
      segment -> {:static, segment}
    end)
  end

  defp split(path), do: String.split(path, "/", trim: true)

  defp bind([], [], params), do: {:ok, params}

  defp bind([{:static, same} | pattern], [same | segments], params),
    do: bind(pattern, segments, params)

  defp bind([{:param, name} | pattern], [value | segments], params),
    do: bind(pattern, segments, Map.put(params, name, value))

  defp bind(_pattern, _segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
