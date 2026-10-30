defmodule TinyRouter do
  @moduledoc """
  A small path router declared at compile time.

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

  `use TinyRouter` defines the `c:routes/0` and `c:match/1` functions in the
  calling module:

      MyApp.Router.routes()
      #=> [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{"id" => "42"}}

      MyApp.Router.match("/missing")
      #=> :error

  Routes are tried in declaration order and the first match wins, so declare
  `/users/new` before `/users/:id`. Paths are compared segment by segment and
  empty segments are ignored, so `/users/42/` matches `/users/:id`.

  To stop `mix format` adding parentheses to `get`, add this to your
  `.formatter.exs`:

      locals_without_parens: [get: 2]
  """

  @typedoc "A declared route."
  @type route :: {path :: String.t(), handler :: module()}

  @typedoc "Values of the `:name` segments, keyed by name as strings."
  @type params :: %{optional(String.t()) => String.t()}

  @doc "Returns the declared routes in declaration order."
  @callback routes() :: [route()]

  @doc """
  Finds the first route matching a request path.

  Returns the route's handler and the values of its `:name` segments, or
  `:error` if no route matches.
  """
  @callback match(path :: String.t()) :: {:ok, handler :: module(), params()} | :error

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour TinyRouter
      @before_compile TinyRouter

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)

      import TinyRouter, only: [get: 2]
    end
  end

  @doc """
  Declares a route from `path` to the module `handler`.

  A segment of `path` written as `:name` matches any single segment and is
  returned in the params under `"name"`.

  Compilation fails with a `CompileError` if `path` is not a string or `handler`
  is not a module name such as `MyApp.PageHandler`. The handler module does not
  have to exist yet.
  """
  defmacro get(path, handler) do
    # Expanding the alias as if inside a function records a runtime dependency,
    # so changing a handler does not recompile every router that names it.
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:match, 1}})
    location = Macro.Env.location(__CALLER__)

    quote do
      TinyRouter.__route__(__MODULE__, unquote(path), unquote(handler), unquote(location))
    end
  end

  @doc false
  def __route__(module, path, handler, location) do
    cond do
      not is_binary(path) ->
        compile_error!(location, "route path must be a string, got: #{inspect(path)}")

      not module_name?(handler) ->
        compile_error!(
          location,
          "route handler must be a module name such as MyApp.PageHandler, " <>
            "got: #{inspect(handler)}"
        )

      true ->
        Module.put_attribute(module, :tiny_router_routes, {path, handler})
    end
  end

  @doc false
  def __segments__(path), do: String.split(path, "/", trim: true)

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()

    quote do
      @impl TinyRouter
      def routes, do: unquote(Macro.escape(routes))

      @impl TinyRouter
      def match(path) when is_binary(path) do
        path |> TinyRouter.__segments__() |> __match__()
      end

      unquote_splicing(Enum.map(routes, &match_clause/1))

      defp __match__(_segments), do: :error
    end
  end

  defp match_clause({path, handler}) do
    {pattern, params} =
      path
      |> __segments__()
      |> Enum.map_reduce([], fn
        ":" <> name, params ->
          var = Macro.unique_var(:param, __MODULE__)
          {var, [{name, var} | params]}

        literal, params ->
          {literal, params}
      end)

    quote do
      defp __match__(unquote(pattern)) do
        {:ok, unquote(handler), %{unquote_splicing(params)}}
      end
    end
  end

  defp module_name?(term), do: is_atom(term) and Macro.classify_atom(term) == :alias

  defp compile_error!(location, description) do
    raise CompileError, [description: description] ++ location
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
