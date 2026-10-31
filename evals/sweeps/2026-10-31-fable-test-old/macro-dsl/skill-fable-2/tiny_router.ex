defmodule TinyRouter do
  @moduledoc """
  A small router DSL (domain-specific language) that compiles declared
  routes into a `routes/0` and a `match/1` function in your module.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0`
  > and `match/1` in your module once all routes are declared.

  ## Example

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

  A segment that starts with `:` matches any single request segment and
  binds it under that name in the params map. Routes are tried in
  declaration order and the first one that matches wins. Leading, trailing
  and repeated slashes are ignored, so `"/users/42/"` matches `"/users/:id"`.
  """

  @typedoc "A route pattern as written in `get/2`, such as `\"/users/:id\"`."
  @type path :: String.t()

  @typedoc "Values bound by `:name` segments of the matched route."
  @type params :: %{optional(atom()) => String.t()}

  @typep segment :: String.t() | {:param, atom()}

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route that sends requests for `path` to `handler`.

  `path` must be a string and `handler` must be a module name. Anything
  else raises `ArgumentError` while the declaring module compiles.
  """
  defmacro get(path, handler) do
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:match, 1}})

    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    compiled_routes = Enum.map(routes, fn {path, handler} -> {parse_segments(path), handler} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{TinyRouter.path(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc """
      Finds the first declared route that matches `request_path`.

      Returns `{:ok, handler, params}` or `:error` when no route matches.
      """
      @spec match(String.t()) :: {:ok, module(), TinyRouter.params()} | :error
      def match(request_path) when is_binary(request_path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled_routes)), request_path)
      end
    end
  end

  @doc false
  @spec __define__(module(), path(), module()) :: :ok
  def __define__(module, path, handler)
      when is_binary(path) and is_atom(handler) and handler not in [nil, true, false] do
    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  def __define__(_module, path, _handler) when not is_binary(path) do
    raise ArgumentError,
          "expected the route path to be a string such as \"/users/:id\", got: #{inspect(path)}"
  end

  def __define__(_module, path, handler) do
    raise ArgumentError,
          "expected the handler for #{inspect(path)} to be a module name, got: #{inspect(handler)}"
  end

  @doc false
  @spec __match__([{[segment()], module()}], String.t()) :: {:ok, module(), params()} | :error
  def __match__(compiled_routes, request_path) do
    request_segments = String.split(request_path, "/", trim: true)
    Enum.find_value(compiled_routes, :error, &match_route(&1, request_segments))
  end

  defp parse_segments(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&parse_segment/1)
  end

  defp parse_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp parse_segment(literal), do: literal

  defp match_route({pattern, handler}, request_segments) do
    case bind_params(pattern, request_segments, %{}) do
      {:ok, params} -> {:ok, handler, params}
      :error -> nil
    end
  end

  defp bind_params([], [], params), do: {:ok, params}

  defp bind_params([{:param, name} | pattern], [value | request_segments], params) do
    bind_params(pattern, request_segments, Map.put(params, name, value))
  end

  defp bind_params([literal | pattern], [literal | request_segments], params) do
    bind_params(pattern, request_segments, params)
  end

  defp bind_params(_pattern, _request_segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
