defmodule TinyRouter do
  @moduledoc """
  A small router: declare routes with `get/2`, then match request paths.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and, once the module body
  > has run, defines `routes/0` and `match/1` in your module.

  Routes are matched in declaration order; the first route that fits wins.

  ## Examples

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.routes()
      #=> [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{id: "42"}}

      MyApp.Router.match("/missing")
      #=> :error
  """

  @typedoc "A declared route: the path as written and the handler module."
  @type route :: {String.t(), module()}

  @typedoc "Values captured by `:name` segments, keyed by the segment name."
  @type params :: %{optional(atom()) => String.t()}

  @typep segment :: String.t() | {:param, atom()}
  @typep compiled_route :: {module(), [segment()]}

  @doc false
  @spec __using__(keyword()) :: Macro.t()
  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route for `path`, handled by the `handler` module.

  A segment written as `:name` matches any single segment and is returned
  under the key `:name` in the params of `match/1`.

  Raises `ArgumentError` when the module compiles if `path` is not a string
  or `handler` is not a module name.
  """
  @spec get(Macro.t(), Macro.t()) :: Macro.t()
  defmacro get(path, handler) do
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:get, 2}})

    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  @spec __before_compile__(Macro.Env.t()) :: Macro.t()
  defmacro __before_compile__(env) do
    routes = Enum.reverse(Module.get_attribute(env.module, :tiny_router_routes))
    declared = for {path, handler, _pattern} <- routes, do: {path, handler}
    compiled = for {_path, handler, pattern} <- routes, do: {handler, pattern}

    quote do
      @spec routes() :: [TinyRouter.route()]
      def routes, do: unquote(Macro.escape(declared))

      @spec match(String.t()) :: {:ok, module(), TinyRouter.params()} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
      end
    end
  end

  @doc false
  @spec __define__(module(), String.t(), module()) :: :ok
  def __define__(module, path, handler) do
    if not is_binary(path), do: raise(ArgumentError, path_message(path))
    if not module_name?(handler), do: raise(ArgumentError, handler_message(handler))
    Module.put_attribute(module, :tiny_router_routes, {path, handler, segments(path)})
  end

  @doc false
  @spec __match__([compiled_route()], String.t()) :: {:ok, module(), params()} | :error
  def __match__(routes, path) when is_binary(path) do
    find_route(routes, String.split(path, "/", trim: true))
  end

  defp path_message(path) do
    "expected the route path to be a string, got: #{inspect(path)}"
  end

  defp handler_message(handler) do
    "expected the route handler to be a module name, got: #{inspect(handler)}"
  end

  defp module_name?(handler) do
    is_atom(handler) and Macro.classify_atom(handler) == :alias
  end

  defp segments(path) do
    Enum.map(String.split(path, "/", trim: true), &parse_segment/1)
  end

  # The atom comes from a path literal in the developer's own module and is
  # created while that module compiles, so request input never reaches the atom table.
  defp parse_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp parse_segment(literal), do: literal

  defp find_route([], _request), do: :error

  defp find_route([{handler, pattern} | routes], request) do
    case match_segments(pattern, request, %{}) do
      {:ok, params} ->
        {:ok, handler, params}

      :error ->
        find_route(routes, request)
    end
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, name} | pattern], [value | request], params) do
    match_segments(pattern, request, Map.put(params, name, value))
  end

  defp match_segments([segment | pattern], [segment | request], params) do
    match_segments(pattern, request, params)
  end

  defp match_segments(_pattern, _request, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
