defmodule TinyRouter do
  @moduledoc """
  A small routing DSL (domain-specific language) that maps request paths to
  handler modules.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` into your module and, once
  > the module body has run, defines `routes/0` and `match/1` in it.

  Declare routes with `get/2`. A path segment that starts with `:` is a
  parameter and matches any one segment of the request path. Routes are tried
  in declaration order and the first match wins. Leading and trailing slashes
  do not take part in matching, so `"/users/42/"` matches `"/users/:id"`.

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

  A path that is not a string, or a handler that is not a module name, raises
  `ArgumentError` while the router module compiles.

  ## Examples

      iex> MyApp.Router.routes()
      [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      iex> MyApp.Router.match("/users/42")
      {:ok, MyApp.UserHandler, %{id: "42"}}

      iex> MyApp.Router.match("/")
      {:ok, MyApp.PageHandler, %{}}

      iex> MyApp.Router.match("/users/42/posts")
      :error
  """

  @typedoc "A declared route: the path as written and its handler module."
  @type route :: {String.t(), module()}

  @typedoc "The values bound to the `:name` segments of a matched route."
  @type params :: %{optional(atom()) => String.t()}

  @typedoc false
  @type segment :: String.t() | {:param, atom()}

  @typedoc false
  @type table :: [{[segment()], module()}]

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route from `path` to `handler`.

  `path` must be a string. A segment written `:name` binds that segment of
  the request path under the key `:name` in the params returned by `match/1`.
  `handler` must be a module name such as `MyApp.PageHandler`; the module is
  stored, not called, so it need not be compiled before the router.

  ## Examples

      get "/", MyApp.PageHandler
      get "/users/:id", MyApp.UserHandler
  """
  defmacro get(path, handler) do
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:match, 1}})

    quote do
      TinyRouter.__route__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = Enum.reverse(Module.get_attribute(env.module, :tiny_router_routes))
    table = Enum.map(routes, fn {path, handler} -> {compile_path(path), handler} end)

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
  @spec __match__(table(), String.t()) :: {:ok, module(), params()} | :error
  def __match__(table, request_path) do
    find_route(table, String.split(request_path, "/", trim: true))
  end

  defp validate_path!(path) when is_binary(path), do: :ok

  defp validate_path!(path) do
    raise ArgumentError, "route path must be a string, got: #{inspect(path)}"
  end

  defp validate_handler!(handler) do
    if is_atom(handler) and Macro.classify_atom(handler) == :alias do
      :ok
    else
      raise ArgumentError,
            "route handler must be a module name such as MyApp.PageHandler, " <>
              "got: #{inspect(handler)}"
    end
  end

  defp compile_path(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&compile_segment/1)
  end

  # Paths are literals in the router's own source and are read once, when it
  # compiles, so turning parameter names into atoms cannot exhaust the atom table.
  defp compile_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp compile_segment(literal), do: literal

  defp find_route([], _request_segments), do: :error

  defp find_route([{pattern, handler} | table], request_segments) do
    case bind_params(pattern, request_segments, %{}) do
      {:ok, params} ->
        {:ok, handler, params}

      :error ->
        find_route(table, request_segments)
    end
  end

  defp bind_params([], [], params) do
    {:ok, params}
  end

  defp bind_params([{:param, key} | pattern], [value | request_segments], params) do
    bind_params(pattern, request_segments, Map.put(params, key, value))
  end

  defp bind_params([literal | pattern], [literal | request_segments], params) do
    bind_params(pattern, request_segments, params)
  end

  defp bind_params(_pattern, _request_segments, _params) do
    :error
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
