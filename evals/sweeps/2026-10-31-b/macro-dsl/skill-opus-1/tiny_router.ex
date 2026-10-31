defmodule TinyRouter do
  @moduledoc """
  Declares routes at compile time and matches request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0` and
  > `match/1` in your module.

  `routes/0` returns the `{path, handler}` pairs in declaration order.

  `match/1` takes a request path and returns `{:ok, handler, params}` for the
  first declared route that fits, or `:error`. `params` maps each `:name`
  segment of the route to the text at that position, without URL decoding.
  Empty segments are ignored, so `/users/42/` matches `/users/:id`.

  Add `import_deps: [:tiny_router]` to your `.formatter.exs` so that `mix format`
  leaves `get/2` calls without parentheses.

  ## Examples

      iex> defmodule Blog.Router do
      ...>   use TinyRouter
      ...>
      ...>   get "/", Blog.HomeHandler
      ...>   get "/posts/:id", Blog.PostHandler
      ...> end
      iex> Blog.Router.routes()
      [{"/", Blog.HomeHandler}, {"/posts/:id", Blog.PostHandler}]
      iex> Blog.Router.match("/posts/42")
      {:ok, Blog.PostHandler, %{id: "42"}}
      iex> Blog.Router.match("/missing")
      :error
  """

  @typedoc "A declared path and the handler module that serves it."
  @type route :: {path :: String.t(), handler :: module()}

  @typedoc "The values of a route's `:name` segments, keyed by name."
  @type params :: %{optional(atom()) => String.t()}

  @doc false
  defmacro __using__([]) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route from `path` to the `handler` module.

  Compiling the router raises `ArgumentError` when `path` is not a string, when
  two `:name` segments of `path` share a name, when a `:name` segment has no
  name, or when `handler` is not a module name.
  """
  defmacro get(path, handler) do
    # The router only stores the handler, so expanding it as if inside match/1
    # keeps it a runtime dependency: editing a handler recompiles no router.
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:match, 1}})

    quote do
      TinyRouter.__route__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = Enum.reverse(Module.get_attribute(env.module, :tiny_router_routes))
    match_clauses = Enum.map(routes, &match_clause/1)

    quote do
      @spec routes() :: [TinyRouter.route()]
      def routes, do: unquote(Macro.escape(routes))

      @spec match(String.t()) :: {:ok, module(), TinyRouter.params()} | :error
      def match(path) when is_binary(path), do: __match__(TinyRouter.__segments__(path))

      unquote(match_clauses)
      defp __match__(_segments), do: :error
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
  @spec __segments__(String.t()) :: [String.t()]
  def __segments__(path), do: String.split(path, "/", trim: true)

  defp validate_path!(path) when is_binary(path) do
    names = for ":" <> name <- __segments__(path), do: name

    if "" in names or names != Enum.uniq(names) do
      raise ArgumentError, "get/2 expects unique, named :params, got: #{inspect(path)}"
    end
  end

  defp validate_path!(path) do
    raise ArgumentError, "get/2 expects the path to be a string, got: #{inspect(path)}"
  end

  defp validate_handler!(handler) do
    if not (is_atom(handler) and Macro.classify_atom(handler) == :alias) do
      raise ArgumentError, "get/2 expects a module name as handler, got: #{inspect(handler)}"
    end
  end

  defp match_clause({path, handler}) do
    pattern = Enum.map(__segments__(path), &segment_pattern/1)
    params = for {name, _meta, _context} = variable <- pattern, do: {name, variable}

    quote do
      defp __match__(unquote(pattern)), do: {:ok, unquote(handler), %{unquote_splicing(params)}}
    end
  end

  # These atoms come from paths in the router's source, never from a request.
  defp segment_pattern(":" <> name), do: Macro.var(String.to_atom(name), __MODULE__)
  defp segment_pattern(literal), do: literal
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
