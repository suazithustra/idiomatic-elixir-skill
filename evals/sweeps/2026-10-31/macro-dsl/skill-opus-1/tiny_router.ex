defmodule TinyRouter do
  @moduledoc """
  A small router whose routes are declared in your own module.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports the `get/2` macro and defines
  > `routes/0` and `match/1` in your module.

  ## Examples

      iex> defmodule Blog.Router do
      ...>   use TinyRouter
      ...>
      ...>   get "/", Blog.PageHandler
      ...>   get "/users/me", Blog.ProfileHandler
      ...>   get "/users/:id", Blog.UserHandler
      ...> end
      iex> Blog.Router.routes()
      [{"/", Blog.PageHandler}, {"/users/me", Blog.ProfileHandler}, {"/users/:id", Blog.UserHandler}]
      iex> Blog.Router.match("/users/me")
      {:ok, Blog.ProfileHandler, %{}}
      iex> Blog.Router.match("/users/42")
      {:ok, Blog.UserHandler, %{id: "42"}}
      iex> Blog.Router.match("/missing")
      :error

  ## Matching

  `match/1` tries the routes in declaration order and the first match wins, so
  declare `/users/me` before `/users/:id`. It returns parameters in a map with
  atom keys and string values.

  Empty segments are ignored, so `/users/42/` matches `/users/:id`. `match/1`
  takes the path alone, without a query string, and does not percent-decode it.

  ## Formatting

  To stop `mix format` adding parentheses to `get`, put
  `locals_without_parens: [get: 2]` in your `.formatter.exs`.
  """

  @typedoc "The `:id`-style segments of a matched route, by name."
  @type params :: %{optional(atom()) => String.t()}

  @doc false
  @spec __using__(Macro.t()) :: Macro.t()
  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route from `path` to `handler`.

  A segment of `path` that starts with `:`, such as `:id`, captures that segment
  of the request path. Names start with a lowercase letter, hold only letters,
  digits and underscores, and appear once in a path.

  `handler` is an Elixir module name such as `MyApp.UserHandler`. The router
  stores it without calling it, so the module need not exist when the router
  compiles, and changing it does not recompile the router.

  Raises `ArgumentError` while the router compiles when `path` is not a string
  or breaks the rules for names, or when `handler` is not a module name.
  """
  @spec get(Macro.t(), Macro.t()) :: Macro.t()
  defmacro get(path, handler) do
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:match, 1}})

    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  @spec __before_compile__(Macro.Env.t()) :: Macro.t()
  defmacro __before_compile__(env) do
    routes = Enum.reverse(Module.get_attribute(env.module, :tiny_router_routes))
    match_clauses = Enum.map(routes, &match_clause/1)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc "Returns `{:ok, handler, params}` for the first route matching `path`, or `:error`."
      @spec match(String.t()) :: {:ok, module(), TinyRouter.params()} | :error
      def match(path) when is_binary(path) do
        __match_segments__(TinyRouter.__segments__(path))
      end

      unquote_splicing(match_clauses)

      defp __match_segments__(_segments), do: :error
    end
  end

  @doc false
  @spec __define__(module(), term(), term()) :: :ok
  def __define__(module, path, handler) do
    validate_path!(path)
    validate_handler!(path, handler)
    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  @doc false
  @spec __segments__(String.t()) :: [String.t()]
  def __segments__(path), do: String.split(path, "/", trim: true)

  defp validate_path!(path) when is_binary(path) do
    names = param_names(path)

    if names != Enum.uniq(names) do
      raise ArgumentError, "route #{inspect(path)} uses a parameter name more than once"
    end

    if not Enum.all?(names, &String.match?(&1, ~r/\A[a-z]\w*\z/)) do
      raise ArgumentError,
            "route #{inspect(path)} has an invalid parameter name, " <>
              "expected a name such as :id or :user_id"
    end
  end

  defp validate_path!(path) do
    raise ArgumentError,
          "expected a route path to be a string such as \"/users/:id\", got: #{inspect(path)}"
  end

  defp validate_handler!(path, handler) do
    if not module_name?(handler) do
      raise ArgumentError,
            "expected the handler of route #{inspect(path)} to be a module name " <>
              "such as MyApp.UserHandler, got: #{inspect(handler)}"
    end
  end

  # nil, true and false are atoms, as is any lowercase atom, so is_atom/1 is not enough.
  defp module_name?(handler) when is_atom(handler) do
    match?("Elixir." <> _name, Atom.to_string(handler))
  end

  defp module_name?(_handler), do: false

  defp match_clause({path, handler}) do
    pattern = Enum.map(__segments__(path), &segment_pattern/1)

    params =
      for name <- param_names(path) do
        {param_key(name), param_var(name)}
      end

    quote do
      defp __match_segments__(unquote(pattern)) do
        {:ok, unquote(handler), %{unquote_splicing(params)}}
      end
    end
  end

  defp segment_pattern(":" <> name), do: param_var(name)
  defp segment_pattern(literal), do: literal

  defp param_names(path) do
    for ":" <> name <- __segments__(path) do
      name
    end
  end

  # Runs at compile time on paths written in source code, never on request input.
  defp param_key(name), do: String.to_atom(name)

  defp param_var(name), do: Macro.var(param_key(name), __MODULE__)
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
