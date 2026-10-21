defmodule TinyRouter do
  @moduledoc """
  Declares routes as `{path, handler}` pairs and matches request paths against them.

  Add `use TinyRouter` to a module, then declare routes with `get/2`:

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

  The module gets two functions:

    * `routes/0` returns the declared `{path, handler}` pairs in declaration order.
    * `match/1` returns `{:ok, handler, params}` for the first matching route, or `:error`.
      Segments that start with `:` are captured into `params` under an atom key.

  `get/2` raises a `CompileError` when the path is not a string literal or the
  handler is not a module name.
  """

  @doc false
  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route from `path` to `handler`.

  `path` must be a string literal. `handler` must be a module name written as an
  alias, such as `MyApp.PageHandler`.
  """
  defmacro get(path, handler) do
    path = Macro.expand(path, __CALLER__)
    handler = Macro.expand(handler, __CALLER__)
    validate_route!(path, handler, __CALLER__)

    quote do
      TinyRouter.__put_route__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  def __put_route__(module, path, handler) do
    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = Enum.reverse(Module.get_attribute(env.module, :tiny_router_routes))

    quote do
      def routes, do: unquote(Macro.escape(routes))

      def match(path) when is_binary(path), do: TinyRouter.__match__(routes(), path)
    end
  end

  @doc false
  def __match__(routes, path) do
    segments = split(path)

    Enum.find_value(routes, :error, fn {route, handler} ->
      case bind(split(route), segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp validate_route!(path, handler, env) do
    case route_error(path, handler) do
      nil -> :ok
      message -> raise CompileError, file: env.file, line: env.line, description: message
    end
  end

  defp route_error(path, _handler) when not is_binary(path) do
    "get/2 expects the path to be a string literal, got: #{Macro.to_string(path)}"
  end

  defp route_error(_path, handler) when not is_atom(handler) or handler in [nil, true, false] do
    "get/2 expects the handler to be a module name, got: #{Macro.to_string(handler)}"
  end

  defp route_error(_path, _handler), do: nil

  defp split(path), do: String.split(path, "/", trim: true)

  defp bind([], [], params), do: {:ok, params}

  # Route names come from the router source, not from requests, so creating atoms here is bounded.
  defp bind([":" <> name | pattern], [value | rest], params) do
    bind(pattern, rest, Map.put(params, String.to_atom(name), value))
  end

  defp bind([segment | pattern], [segment | rest], params), do: bind(pattern, rest, params)
  defp bind(_pattern, _segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
