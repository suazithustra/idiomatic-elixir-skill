defmodule TinyRouter do
  @moduledoc """
  A small path router. Declare routes in your own module with `get/2`.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0` and
  > `match/1` in your module.

  Routes are tried in declaration order and the first match wins, so declare
  `"/users/new"` before `"/users/:id"`.

  A path segment that starts with `:` matches any one segment of the request
  path. `match/1` returns the text it matched, not percent-decoded, in `params`
  under the segment's name as a string key. Empty segments are ignored, so
  `"/users/42/"` matches `"/users/:id"`.

  Add `import_deps: [:tiny_router]` to your `.formatter.exs` so that `mix format`
  keeps `get` without parentheses.

  ## Examples

      iex> defmodule MyApp.Router do
      ...>   use TinyRouter
      ...>
      ...>   get "/", MyApp.PageHandler
      ...>   get "/users/:id", MyApp.UserHandler
      ...> end
      iex> MyApp.Router.routes()
      [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]
      iex> MyApp.Router.match("/users/42")
      {:ok, MyApp.UserHandler, %{"id" => "42"}}
      iex> MyApp.Router.match("/missing")
      :error
  """

  @typedoc "Values captured from `:name` path segments, keyed by segment name."
  @type params :: %{String.t() => String.t()}

  @typep segment :: String.t() | {:param, String.t()}

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

  `path` must be a string and `handler` an Elixir module name, such as
  `MyApp.PageHandler`. Anything else raises `ArgumentError` while the router
  module compiles.
  """
  defmacro get(path, handler) do
    # The router only stores the handler, so it needs no compile-time dependency on it.
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:match, 1}})

    quote do
      TinyRouter.__route__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = Enum.reverse(Module.get_attribute(env.module, :tiny_router_routes))
    patterns = for {path, handler} <- routes, do: {parse_path(path), handler}

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc "Returns `{:ok, handler, params}` for the first route matching `path`, or `:error`."
      @spec match(String.t()) :: {:ok, module(), TinyRouter.params()} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(patterns)), path)
      end
    end
  end

  @doc false
  @spec __route__(module(), String.t(), module()) :: :ok
  def __route__(router, path, handler) do
    validate_path!(path)
    validate_handler!(handler, path)
    Module.put_attribute(router, :tiny_router_routes, {path, handler})
  end

  @doc false
  @spec __match__([{[segment()], module()}], String.t()) :: {:ok, module(), params()} | :error
  def __match__(patterns, path) do
    segments = split_path(path)
    Enum.find_value(patterns, :error, &match_route(&1, segments))
  end

  defp validate_path!(path) do
    if not is_binary(path) do
      raise ArgumentError, "invalid route path: expected a string, got: #{inspect(path)}"
    end
  end

  defp validate_handler!(handler, path) do
    if not module_name?(handler) do
      raise ArgumentError,
            "invalid handler for route #{inspect(path)}: expected a module name " <>
              "such as MyApp.PageHandler, got: #{inspect(handler)}"
    end
  end

  # An atom such as nil or :home passes is_atom/1 but cannot name an Elixir module.
  defp module_name?(handler), do: is_atom(handler) and Macro.classify_atom(handler) == :alias

  defp parse_path(path), do: Enum.map(split_path(path), &parse_segment/1)

  defp parse_segment(":" <> name), do: {:param, name}
  defp parse_segment(literal), do: literal

  defp split_path(path), do: String.split(path, "/", trim: true)

  defp match_route({pattern, handler}, segments) do
    case capture_params(pattern, segments, %{}) do
      {:ok, params} -> {:ok, handler, params}
      :error -> nil
    end
  end

  defp capture_params([], [], params), do: {:ok, params}

  defp capture_params([{:param, name} | pattern], [value | segments], params) do
    capture_params(pattern, segments, Map.put(params, name, value))
  end

  defp capture_params([literal | pattern], [literal | segments], params) do
    capture_params(pattern, segments, params)
  end

  defp capture_params(_pattern, _segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
