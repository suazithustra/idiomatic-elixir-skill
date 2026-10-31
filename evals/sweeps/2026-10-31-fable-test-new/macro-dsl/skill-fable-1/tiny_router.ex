defmodule TinyRouter do
  @moduledoc """
  A small router: declare `get` routes in a module and match request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` into your module and, once
  > the module is compiled, defines `routes/0` and `match/1` in it.

  ## Examples

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

  A segment written `:name` matches any one segment of the request path and
  comes back under `name` in the params map. Routes are tried in declaration
  order and the first match wins.

      iex> MyApp.Router.routes()
      [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      iex> MyApp.Router.match("/users/42")
      {:ok, MyApp.UserHandler, %{id: "42"}}

      iex> MyApp.Router.match("/missing")
      :error

  A path that is not a string, or a handler that is not a module name, raises
  `ArgumentError` when the router module compiles.
  """

  @typedoc "A declared route: the path pattern and the module that handles it."
  @type route :: {String.t(), module()}

  @typedoc "Values captured from `:name` segments, keyed by the segment name."
  @type params :: %{optional(atom()) => String.t()}

  @typedoc false
  @type segment :: String.t() | {:param, atom()}

  @typedoc false
  @type compiled_route :: {[segment()], module()}

  @spec __using__(keyword()) :: Macro.t()
  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route that sends requests for `path` to `handler`.

  `path` is a string such as `"/users/:id"`, where a segment starting with `:`
  captures the matching request segment. `handler` is a module name. Both are
  checked when the router module compiles.
  """
  @spec get(Macro.t(), Macro.t()) :: Macro.t()
  defmacro get(path, handler) do
    # Expanding the alias as if inside a function keeps the handler a runtime
    # dependency, so editing a handler does not recompile the router.
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:get, 2}})

    quote do
      TinyRouter.__route__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @spec __before_compile__(Macro.Env.t()) :: Macro.t()
  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(:tiny_router_routes)
      |> Enum.reverse()

    compiled_routes = Enum.map(routes, fn {path, handler} -> {segments(path), handler} end)

    quote do
      @spec routes() :: [TinyRouter.route()]
      def routes, do: unquote(Macro.escape(routes))

      @spec match(String.t()) :: {:ok, module(), TinyRouter.params()} | :error
      def match(request_path) when is_binary(request_path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled_routes)), request_path)
      end
    end
  end

  @doc false
  @spec __route__(module(), term(), term()) :: :ok
  def __route__(module, path, handler) do
    validate_path!(path)
    validate_handler!(handler)
    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  @doc false
  @spec __match__([compiled_route()], String.t()) :: {:ok, module(), params()} | :error
  def __match__(compiled_routes, request_path) do
    find_route(compiled_routes, split_path(request_path))
  end

  defp validate_path!(path) when is_binary(path), do: :ok

  defp validate_path!(path) do
    raise ArgumentError, "get/2 expects the path to be a string, got: #{inspect(path)}"
  end

  defp validate_handler!(handler) when is_atom(handler) do
    if Macro.classify_atom(handler) == :alias do
      :ok
    else
      raise ArgumentError, handler_message(handler)
    end
  end

  defp validate_handler!(handler), do: raise(ArgumentError, handler_message(handler))

  defp handler_message(handler) do
    "get/2 expects the handler to be a module name such as MyApp.PageHandler, " <>
      "got: #{inspect(handler)}"
  end

  defp segments(path), do: Enum.map(split_path(path), &parse_segment/1)

  defp split_path(path), do: String.split(path, "/", trim: true)

  # The name comes from a path literal in the router's module body, so the atom
  # is created at compile time and the set of atoms is bounded by the routes.
  defp parse_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp parse_segment(segment), do: segment

  defp find_route([], _segments), do: :error

  defp find_route([{pattern, handler} | compiled_routes], segments) do
    case match_segments(pattern, segments, %{}) do
      {:ok, params} ->
        {:ok, handler, params}

      :error ->
        find_route(compiled_routes, segments)
    end
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, name} | pattern], [value | segments], params) do
    match_segments(pattern, segments, Map.put(params, name, value))
  end

  defp match_segments([segment | pattern], [segment | segments], params) do
    match_segments(pattern, segments, params)
  end

  defp match_segments(_pattern, _segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
