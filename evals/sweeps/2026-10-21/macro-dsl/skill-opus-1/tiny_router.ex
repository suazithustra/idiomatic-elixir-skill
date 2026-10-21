defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it sets `@behaviour TinyRouter`, imports
  > `get/2`, and defines `routes/0` and `match/1` in your module.

  ## Examples

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.routes()
      #=> [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{"id" => "42"}}

      MyApp.Router.match("/posts")
      #=> :error

  Routes are tried in declaration order, so declare `"/users/new"` before
  `"/users/:id"`. Empty segments are ignored, so `"/users/42/"` matches
  `"/users/:id"`.
  """

  @typedoc "A request path or route path, such as `\"/users/:id\"`."
  @type path :: String.t()

  @typedoc "The module a route sends matching requests to."
  @type handler :: module()

  @typedoc "The values of a route's `:name` segments, keyed by name."
  @type params :: %{optional(String.t()) => String.t()}

  @typep segment :: String.t() | {:param, String.t()}

  @doc "Returns the declared routes as `{path, handler}` pairs, in declaration order."
  @callback routes() :: [{path(), handler()}]

  @doc """
  Matches a request path against the declared routes, in declaration order.

  Returns `{:ok, handler, params}` for the first route that matches, or
  `:error` if none does.
  """
  @callback match(path()) :: {:ok, handler(), params()} | :error

  defmacro __using__(_opts) do
    quote do
      @behaviour TinyRouter
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route that sends requests for `path` to `handler`.

  `path` is a string. A segment that starts with `:`, such as `:id` in
  `"/users/:id"`, matches any one segment and puts its value in the params
  under the name after the colon. `handler` is a module name.

  The router fails to compile with an `ArgumentError` if `path` is not a
  string or `handler` is not a module name.

  ## Examples

      get "/users/:id", MyApp.UserHandler
  """
  defmacro get(path, handler) do
    # The router only returns the handler from match/1 and never calls it at
    # compile time, so expanding it as if inside match/1 keeps the dependency
    # a runtime one and editing a handler does not recompile the router.
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:match, 1}})

    quote do
      TinyRouter.__route__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  @spec __route__(module(), term(), term()) :: :ok
  def __route__(module, path, handler) do
    if not is_binary(path) do
      raise ArgumentError, "get/2 expects the path to be a string, got: #{inspect(path)}"
    end

    if not module_name?(handler) do
      raise ArgumentError,
            "get/2 expects the handler to be a module name such as MyApp.PageHandler, " <>
              "got: #{inspect(handler)}"
    end

    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    compiled_routes = Enum.map(routes, fn {path, handler} -> {split_path(path), handler} end)

    quote do
      @impl TinyRouter
      def routes, do: unquote(Macro.escape(routes))

      @impl TinyRouter
      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled_routes)), path)
      end
    end
  end

  @doc false
  @spec __match__([{[segment()], handler()}], path()) :: {:ok, handler(), params()} | :error
  def __match__(compiled_routes, path) do
    segments = String.split(path, "/", trim: true)
    Enum.find_value(compiled_routes, :error, &match_route(&1, segments))
  end

  defp module_name?(handler) when is_atom(handler),
    do: match?("Elixir." <> _, Atom.to_string(handler))

  defp module_name?(_handler), do: false

  defp split_path(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&compile_segment/1)
  end

  defp compile_segment(":" <> name), do: {:param, name}
  defp compile_segment(segment), do: segment

  defp match_route({pattern, handler}, segments) do
    case match_segments(pattern, segments, %{}) do
      {:ok, params} -> {:ok, handler, params}
      :error -> nil
    end
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, name} | pattern], [value | segments], params),
    do: match_segments(pattern, segments, Map.put(params, name, value))

  defp match_segments([segment | pattern], [segment | segments], params),
    do: match_segments(pattern, segments, params)

  defp match_segments(_pattern, _segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
