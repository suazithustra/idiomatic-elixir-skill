defmodule TinyRouter do
  @moduledoc """
  A small path router: declare routes with `get/2`, then match request paths
  against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` into your module and, once
  > the module body has run, defines two functions:
  >
  >   * `routes/0` returns the declared `{path, handler}` pairs in declaration
  >     order.
  >   * `match/1` takes a request path and returns `{:ok, handler, params}` for
  >     the first declared route whose pattern matches, or `:error`. `params`
  >     maps each `:name` segment of the pattern to the request segment it
  >     matched.

  ## Examples

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      iex> MyApp.Router.routes()
      [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      iex> MyApp.Router.match("/users/42")
      {:ok, MyApp.UserHandler, %{id: "42"}}

      iex> MyApp.Router.match("/missing")
      :error

  A path that is not a string, or a handler that is not a module name, raises
  an `ArgumentError` while the router module compiles.
  """

  @typedoc "A declared route: the path pattern and the module that handles it."
  @type route :: {String.t(), module()}

  @typedoc "The request segments captured by `:name` segments, keyed by name."
  @type params :: %{optional(atom()) => String.t()}

  @typedoc false
  @type pattern :: [String.t() | {:param, atom()}]

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route for `path`, handled by `handler`.

  `path` is a string of `/`-separated segments. A segment that starts with `:`
  matches any one request segment and is returned under that name in the
  params of `match/1`. `handler` is the module that handles the request.

  Raises `ArgumentError` while the router compiles when `path` is not a string
  or `handler` is not a module name.
  """
  defmacro get(path, handler) do
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:match, 1}})

    quote do
      TinyRouter.__route__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    table = Enum.map(routes, fn {path, handler} -> {parse_path(path), handler} end)

    quote do
      @spec routes() :: [TinyRouter.route()]
      def routes, do: unquote(Macro.escape(routes))

      @spec match(String.t()) :: {:ok, module(), TinyRouter.params()} | :error
      def match(request_path) when is_binary(request_path) do
        TinyRouter.__match__(unquote(Macro.escape(table)), request_path)
      end
    end
  end

  @doc false
  @spec __route__(module(), String.t(), module()) :: :ok
  def __route__(module, path, handler) do
    validate_path!(path)
    validate_handler!(handler)
    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  @doc false
  @spec __match__([{pattern(), module()}], String.t()) :: {:ok, module(), params()} | :error
  def __match__(table, request_path) do
    find_route(table, split_path(request_path))
  end

  defp validate_path!(path) when is_binary(path), do: :ok

  defp validate_path!(path) do
    raise ArgumentError, "a route path must be a string, got: #{inspect(path)}"
  end

  defp validate_handler!(handler) when is_atom(handler) and handler not in [nil, true, false] do
    :ok
  end

  defp validate_handler!(handler) do
    raise ArgumentError, "a route handler must be a module name, got: #{inspect(handler)}"
  end

  defp parse_path(path), do: Enum.map(split_path(path), &parse_segment/1)

  # Route paths are source code, so the set of param atoms is fixed when the
  # router compiles; no request can add to it.
  defp parse_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp parse_segment(segment), do: segment

  defp split_path(path), do: String.split(path, "/", trim: true)

  defp find_route([], _request_segments), do: :error

  defp find_route([{pattern, handler} | table], request_segments) do
    case match_segments(pattern, request_segments, %{}) do
      {:ok, params} -> {:ok, handler, params}
      :error -> find_route(table, request_segments)
    end
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, name} | pattern], [value | request_segments], params) do
    match_segments(pattern, request_segments, Map.put(params, name, value))
  end

  defp match_segments([segment | pattern], [segment | request_segments], params) do
    match_segments(pattern, request_segments, params)
  end

  defp match_segments(_pattern, _request_segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
