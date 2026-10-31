defmodule TinyRouter do
  @moduledoc """
  A small DSL (domain-specific language) for declaring routes and matching
  request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and, once your module is
  > compiled, defines `routes/0` and `match/1` in it.

  Declare routes with `get/2`. A path segment that starts with `:` is a
  parameter and matches any one segment of the request path:

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

  Routes are tried in declaration order and the first match wins.

  ## Examples

      iex> MyApp.Router.routes()
      [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      iex> MyApp.Router.match("/users/42")
      {:ok, MyApp.UserHandler, %{id: "42"}}

      iex> MyApp.Router.match("/posts")
      :error
  """

  @typedoc "A declared route: the path as written and the module that handles it."
  @type route :: {String.t(), module()}

  @typedoc "The `:name` segments of a matched route, bound to the request's segments."
  @type params :: %{optional(atom()) => String.t()}

  @typedoc false
  @type segment :: {:static, String.t()} | {:param, atom()}

  @typedoc false
  @type compiled_route :: {[segment()], module()}

  @doc false
  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route for `path`, handled by the `handler` module.

  `path` must be a string literal and `handler` a module name; anything else
  raises `ArgumentError` while the router module compiles. The handler is only
  stored, so it does not become a compile-time dependency of the router.
  """
  defmacro get(path, handler) do
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:match, 1}})

    quote do
      TinyRouter.__route__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  @spec __route__(module(), term(), term()) :: :ok
  def __route__(module, path, handler) when is_binary(path) and is_atom(handler) do
    if Macro.classify_atom(handler) == :alias do
      Module.put_attribute(module, :tiny_router_routes, {path, handler})
    else
      raise ArgumentError, handler_message(path, handler)
    end
  end

  def __route__(_module, path, _handler) when not is_binary(path) do
    raise ArgumentError, "expected the path of a route to be a string, got: #{inspect(path)}"
  end

  def __route__(_module, path, handler) do
    raise ArgumentError, handler_message(path, handler)
  end

  defp handler_message(path, handler) do
    "expected the handler of route #{inspect(path)} to be a module name, got: #{inspect(handler)}"
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = Enum.reverse(Module.get_attribute(env.module, :tiny_router_routes))
    compiled = Enum.map(routes, fn {path, handler} -> {compile_path(path), handler} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [TinyRouter.route()]
      def routes, do: unquote(Macro.escape(routes))

      @doc "Matches a request path against the declared routes, first match wins."
      @spec match(String.t()) :: {:ok, module(), TinyRouter.params()} | :error
      def match(path), do: TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
    end
  end

  @doc false
  @spec __match__([compiled_route()], String.t()) :: {:ok, module(), params()} | :error
  def __match__(routes, path) when is_binary(path) do
    find_route(routes, split_path(path))
  end

  defp compile_path(path), do: Enum.map(split_path(path), &compile_segment/1)

  defp compile_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp compile_segment(segment), do: {:static, segment}

  defp split_path(path), do: String.split(path, "/", trim: true)

  defp find_route([], _segments), do: :error

  defp find_route([{pattern, handler} | routes], segments) do
    case bind_params(pattern, segments, %{}) do
      {:ok, params} -> {:ok, handler, params}
      :error -> find_route(routes, segments)
    end
  end

  defp bind_params([], [], params) do
    {:ok, params}
  end

  defp bind_params([{:static, segment} | pattern], [segment | segments], params) do
    bind_params(pattern, segments, params)
  end

  defp bind_params([{:param, name} | pattern], [segment | segments], params) do
    bind_params(pattern, segments, Map.put(params, name, segment))
  end

  defp bind_params(_pattern, _segments, _params) do
    :error
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
