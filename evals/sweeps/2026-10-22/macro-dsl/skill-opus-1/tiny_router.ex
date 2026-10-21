defmodule TinyRouter do
  @moduledoc """
  A small DSL (domain-specific language) for declaring routes and matching
  request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports the `get/2` macro and defines
  > `routes/0` and `match/1` in your module.

  ## Example

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.routes()
      #=> [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{"id" => "42"}}

      MyApp.Router.match("/missing")
      #=> :error

  A path segment written as `:name` matches any single segment of the request
  path and stores it in `params` under the key `"name"`. Routes are tried in
  declaration order and the first match wins. Empty segments are ignored, so
  `"/users/42/"` matches `"/users/:id"`.
  """

  @typedoc "Segments captured by `:name` placeholders, keyed by name."
  @type params :: %{optional(String.t()) => String.t()}

  @typedoc "A declared route: its path and its handler module."
  @type route :: {String.t(), module()}

  @typedoc false
  @type pattern :: {[String.t() | {:param, String.t()}], module()}

  @doc false
  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route that sends requests for `path` to `handler`.

  `path` must be a string and `handler` a module name. Compiling the router
  fails with an `ArgumentError` when either is invalid, when a `:` segment
  has no name, or when a path uses the same `:name` twice.
  """
  defmacro get(path, handler) do
    # The router only stores the handler and never calls it at compile time,
    # so expand it as if it were used inside match/1. This keeps the handler a
    # runtime dependency: editing it does not recompile the router.
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:match, 1}})

    quote do
      TinyRouter.__route__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  @spec __route__(module(), term(), term()) :: :ok
  def __route__(router, path, handler)
      when is_binary(path) and is_atom(handler) and handler not in [nil, true, false] do
    Module.put_attribute(router, :tiny_router_routes, {path, handler, parse_path!(path)})
  end

  def __route__(_router, path, handler) when is_binary(path) do
    raise ArgumentError,
          "get/2 expects the handler for #{inspect(path)} to be a module name, " <>
            "got: #{inspect(handler)}"
  end

  def __route__(_router, path, _handler) do
    raise ArgumentError, "get/2 expects the path to be a string, got: #{inspect(path)}"
  end

  @doc false
  defmacro __before_compile__(env) do
    entries = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    routes = for {path, handler, _segments} <- entries, do: {path, handler}
    patterns = for {_path, handler, segments} <- entries, do: {segments, handler}

    quote do
      @doc "Returns the declared routes as `{path, handler}` pairs, in declaration order."
      @spec routes() :: [TinyRouter.route()]
      def routes, do: unquote(Macro.escape(routes))

      @doc """
      Matches `path` against the declared routes, in declaration order.

      Returns `{:ok, handler, params}` for the first route that matches, or `:error`.
      """
      @spec match(String.t()) :: {:ok, module(), TinyRouter.params()} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(patterns)), path)
      end
    end
  end

  @doc false
  @spec __match__([pattern()], String.t()) :: {:ok, module(), params()} | :error
  def __match__(patterns, path) do
    path_segments = split_path(path)

    Enum.find_value(patterns, :error, fn {route_segments, handler} ->
      case match_segments(route_segments, path_segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp parse_path!(path) do
    segments = Enum.map(split_path(path), &parse_segment!(&1, path))
    names = for {:param, name} <- segments, do: name

    case names -- Enum.uniq(names) do
      [] ->
        segments

      [duplicate | _] ->
        raise ArgumentError, "path #{inspect(path)} uses the segment :#{duplicate} more than once"
    end
  end

  defp parse_segment!(":", path) do
    raise ArgumentError, "path #{inspect(path)} has a \":\" segment without a name"
  end

  defp parse_segment!(":" <> name, _path), do: {:param, name}
  defp parse_segment!(literal, _path), do: literal

  defp split_path(path), do: String.split(path, "/", trim: true)

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, name} | route_rest], [value | path_rest], params) do
    match_segments(route_rest, path_rest, Map.put(params, name, value))
  end

  defp match_segments([literal | route_rest], [literal | path_rest], params) do
    match_segments(route_rest, path_rest, params)
  end

  defp match_segments(_route_segments, _path_segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
