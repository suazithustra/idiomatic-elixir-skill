defmodule TinyRouter do
  @moduledoc """
  A tiny compile-time router DSL.

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

  `MyApp.Router.routes/0` returns the declared `{path, handler}` pairs in
  declaration order, and `MyApp.Router.match/1` returns `{:ok, handler, params}`
  or `:error`.
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)

      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route. The path must be a string literal and the handler a module name.
  """
  defmacro get(path, handler) do
    unless is_binary(path) do
      raise ArgumentError,
            "TinyRouter: route path must be a string, got: #{Macro.to_string(path)}"
    end

    handler = Macro.expand(handler, __CALLER__)

    unless is_atom(handler) do
      raise ArgumentError,
            "TinyRouter: route handler must be a module name, got: #{Macro.to_string(handler)}"
    end

    quote do
      @tiny_router_routes {unquote(path), unquote(handler)}
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    compiled = Enum.map(routes, fn {path, handler} -> {compile_path(path), handler} end)

    quote do
      def routes, do: unquote(Macro.escape(routes))

      def match(request_path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled)), request_path)
      end
    end
  end

  @doc false
  def compile_path(path) do
    path
    |> split()
    |> Enum.map(fn
      ":" <> name -> {:param, name}
      segment -> {:static, segment}
    end)
  end

  @doc false
  def __match__(routes, request_path) do
    segments = split(request_path)

    Enum.find_value(routes, :error, fn {pattern, handler} ->
      case bind(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp bind([], [], params), do: {:ok, params}

  defp bind([{:static, segment} | patterns], [segment | segments], params) do
    bind(patterns, segments, params)
  end

  defp bind([{:param, name} | patterns], [value | segments], params) do
    bind(patterns, segments, Map.put(params, name, value))
  end

  defp bind(_patterns, _segments, _params), do: :error

  defp split(path), do: String.split(path, "/", trim: true)
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
