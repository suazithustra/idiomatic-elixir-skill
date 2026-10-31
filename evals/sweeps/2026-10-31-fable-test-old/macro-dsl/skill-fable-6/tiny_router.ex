defmodule TinyRouter do
  @moduledoc """
  A small path router declared with a `get/2` macro.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` into your module and, once
  > the module is compiled, defines two functions on it:
  >
  >   * `routes/0` - returns the declared `{path, handler}` pairs in
  >     declaration order.
  >   * `match/1` - takes a request path and returns `{:ok, handler, params}`
  >     for the first route that matches, or `:error`.

  A route path is a string of `/`-separated segments. A segment that starts
  with `:` matches any one request segment and binds it under that name in
  `params`. Routes are tried in declaration order, so put a literal path such
  as `"/users/new"` before `"/users/:id"` if both should exist.

  Both arguments of `get/2` are checked when the router compiles: the path
  must be a string and the handler must be a module name, otherwise
  compilation fails with an `ArgumentError` that names the bad argument.

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

      iex> MyApp.Router.match("/users/42/posts")
      :error
  """

  @typedoc "A route path as written in `get/2`, such as `\"/users/:id\"`."
  @type path :: String.t()

  @typedoc "A declared route: the path and the module that handles it."
  @type route :: {path(), module()}

  @typedoc "The `:name` segments of a route, bound to the matching request segments."
  @type params :: %{optional(atom()) => String.t()}

  @typep segment :: {:static, String.t()} | {:param, atom()}
  @typep matcher :: {[segment()], module()}

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route for `path` that is handled by the `handler` module.

  `path` must be a string and `handler` a module name; anything else raises
  an `ArgumentError` when the router module compiles.
  """
  defmacro get(path, handler) do
    # The handler is only stored and returned from `match/1`, never called at
    # compile time, so expand the alias as if it appeared inside `match/1` to
    # keep it a runtime dependency rather than a compile-time one.
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:match, 1}})

    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    matchers = Enum.map(routes, fn {path, handler} -> {segments(path), handler} end)

    quote do
      @spec routes() :: [TinyRouter.route()]
      def routes, do: unquote(Macro.escape(routes))

      @spec match(String.t()) :: {:ok, module(), TinyRouter.params()} | :error
      def match(request_path) when is_binary(request_path) do
        TinyRouter.__match__(unquote(Macro.escape(matchers)), request_path)
      end
    end
  end

  defguardp is_module_name(handler)
            when is_atom(handler) and handler not in [nil, true, false]

  @doc false
  @spec __define__(module(), path(), module()) :: :ok
  def __define__(module, path, handler) when is_binary(path) and is_module_name(handler) do
    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  def __define__(_module, path, _handler) when not is_binary(path) do
    raise ArgumentError,
          "expected the route path to be a string such as \"/users/:id\", got: #{inspect(path)}"
  end

  def __define__(_module, _path, handler) do
    raise ArgumentError,
          "expected the route handler to be a module name such as MyApp.UserHandler, " <>
            "got: #{inspect(handler)}"
  end

  @doc false
  @spec __match__([matcher()], String.t()) :: {:ok, module(), params()} | :error
  def __match__(matchers, request_path) do
    find_route(matchers, String.split(request_path, "/", trim: true))
  end

  defp find_route([], _request_segments), do: :error

  defp find_route([{segments, handler} | matchers], request_segments) do
    case bind_params(segments, request_segments, %{}) do
      {:ok, params} -> {:ok, handler, params}
      :error -> find_route(matchers, request_segments)
    end
  end

  defp bind_params([], [], params), do: {:ok, params}

  defp bind_params([{:static, segment} | segments], [segment | request_segments], params) do
    bind_params(segments, request_segments, params)
  end

  defp bind_params([{:param, name} | segments], [value | request_segments], params) do
    bind_params(segments, request_segments, Map.put(params, name, value))
  end

  defp bind_params(_segments, _request_segments, _params), do: :error

  @spec segments(path()) :: [segment()]
  defp segments(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&segment/1)
  end

  # Route paths are literals written by the developer, not external input, so
  # creating an atom per parameter name at compile time is bounded and safe.
  defp segment(":" <> name), do: {:param, String.to_atom(name)}
  defp segment(literal), do: {:static, literal}
end

defmodule MyApp.PageHandler do
  @moduledoc false
end

defmodule MyApp.UserHandler do
  @moduledoc false
end

defmodule MyApp.Router do
  @moduledoc false
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
