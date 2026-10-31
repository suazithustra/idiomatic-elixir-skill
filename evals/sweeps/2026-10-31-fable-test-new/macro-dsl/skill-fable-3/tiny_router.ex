defmodule TinyRouter do
  @moduledoc """
  A small router: declare routes with `get/2`, then match request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` into your module and, once the
  > module body has run, defines `routes/0` and `match/1` in it.

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
  """

  @typedoc "A declared route: the path pattern and the module that handles it."
  @type route :: {String.t(), module()}

  @typedoc "Values captured by the `:name` segments of the matched path pattern."
  @type params :: %{optional(atom()) => String.t()}

  @typedoc false
  @type compiled_route :: {String.t(), module(), [String.t() | atom()]}

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares that requests for `path` are handled by `handler`.

  A segment written `:name` matches any one segment of the request path, and
  `match/1` returns its value under the key `:name`. Raises `ArgumentError`
  while the router compiles when `path` is not a string or `handler` is not a
  module name.
  """
  defmacro get(path, handler) do
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:match, 1}})

    quote do
      TinyRouter.__route__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  @spec __route__(module(), term(), term()) :: :ok
  def __route__(module, path, handler) do
    validate_path!(path)
    validate_handler!(handler)
    Module.put_attribute(module, :tiny_router_routes, {path, handler, compile_pattern(path)})
  end

  @doc false
  defmacro __before_compile__(env) do
    compiled_routes = Enum.reverse(Module.get_attribute(env.module, :tiny_router_routes))
    routes = Enum.map(compiled_routes, fn {path, handler, _pattern} -> {path, handler} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [TinyRouter.route()]
      def routes, do: unquote(Macro.escape(routes))

      @doc """
      Finds the first declared route that matches `path`.

      Returns `{:ok, handler, params}`, or `:error` when no route matches.
      """
      @spec match(String.t()) :: {:ok, module(), TinyRouter.params()} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled_routes)), path)
      end
    end
  end

  @doc false
  @spec __match__([compiled_route()], String.t()) :: {:ok, module(), params()} | :error
  def __match__(compiled_routes, path) do
    find_route(compiled_routes, String.split(path, "/", trim: true))
  end

  defp validate_path!(path) when is_binary(path), do: :ok

  defp validate_path!(path) do
    raise ArgumentError, "get/2 expects the path to be a string, got: #{inspect(path)}"
  end

  defp validate_handler!(handler) do
    if module_name?(handler) do
      :ok
    else
      raise ArgumentError,
            "get/2 expects the handler to be a module name such as MyApp.PageHandler, " <>
              "got: #{inspect(handler)}"
    end
  end

  defp module_name?(handler), do: is_atom(handler) and Macro.classify_atom(handler) == :alias

  defp compile_pattern(path) do
    Enum.map(String.split(path, "/", trim: true), &compile_segment/1)
  end

  # The path is a literal in the router's source and is converted once, while
  # the router compiles, so the atoms created here are bounded by the code.
  defp compile_segment(":" <> name), do: String.to_atom(name)
  defp compile_segment(static), do: static

  defp find_route([], _segments), do: :error

  defp find_route([{_path, handler, pattern} | rest], segments) do
    case match_segments(pattern, segments, %{}) do
      {:ok, params} ->
        {:ok, handler, params}

      :error ->
        find_route(rest, segments)
    end
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([static | pattern], [static | segments], params) when is_binary(static) do
    match_segments(pattern, segments, params)
  end

  defp match_segments([name | pattern], [value | segments], params) when is_atom(name) do
    match_segments(pattern, segments, Map.put(params, name, value))
  end

  defp match_segments(_pattern, _segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
