defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0` and
  > `match/1` in your module.

  `routes/0` returns the declared `{path, handler}` pairs in declaration order.
  `match/1` takes a request path and returns `{:ok, handler, params}` for the
  first route that matches it, or `:error`. A route segment that starts with
  `:`, such as `:id` in `"/users/:id"`, matches any one segment of the request
  path, and `params` holds that segment under its name. Empty segments are
  ignored, so `"/users/42/"` matches `"/users/:id"`.

  ## Examples

      iex> defmodule Demo.Router do
      ...>   use TinyRouter
      ...>
      ...>   get "/", Demo.PageHandler
      ...>   get "/users/:id", Demo.UserHandler
      ...> end
      iex> Demo.Router.routes()
      [{"/", Demo.PageHandler}, {"/users/:id", Demo.UserHandler}]
      iex> Demo.Router.match("/users/42")
      {:ok, Demo.UserHandler, %{"id" => "42"}}
      iex> Demo.Router.match("/posts/42")
      :error
  """

  @typedoc "A declared route: its path and its handler module."
  @type route :: {String.t(), module()}

  @typedoc "The request path segments a route's `:name` segments matched, keyed by name."
  @type params :: %{optional(String.t()) => String.t()}

  @doc false
  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route that sends requests for `path` to `handler`.

  `path` must be a string and `handler` a module name. Anything else raises
  `ArgumentError` while the router module compiles.
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
    validate_handler!(path, handler)
    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  @doc false
  @spec __split_path__(String.t()) :: [String.t()]
  def __split_path__(path), do: String.split(path, "/", trim: true)

  @doc false
  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(:tiny_router_routes)
      |> Enum.reverse()

    match_clauses = Enum.map(routes, &match_clause/1)

    quote do
      @spec routes() :: [TinyRouter.route()]
      def routes, do: unquote(Macro.escape(routes))

      @spec match(String.t()) :: {:ok, module(), TinyRouter.params()} | :error
      def match(path) when is_binary(path) do
        path
        |> TinyRouter.__split_path__()
        |> __match_segments__()
      end

      unquote(match_clauses)

      defp __match_segments__(_segments), do: :error
    end
  end

  defp validate_path!(path) when is_binary(path), do: :ok

  defp validate_path!(path) do
    raise ArgumentError, "get/2 expects the path to be a string, got: #{inspect(path)}"
  end

  defguardp is_module_name(term) when is_atom(term) and term not in [nil, true, false]

  defp validate_handler!(_path, handler) when is_module_name(handler), do: :ok

  defp validate_handler!(path, handler) do
    message =
      "get/2 expects the handler for #{inspect(path)} to be a module name, " <>
        "such as MyApp.PageHandler, got: #{inspect(handler)}"

    raise ArgumentError, message
  end

  defp match_clause({path, handler}) do
    {pattern, params} = Enum.map_reduce(__split_path__(path), [], &segment_pattern/2)

    quote do
      defp __match_segments__(unquote(pattern)) do
        {:ok, unquote(handler), %{unquote_splicing(params)}}
      end
    end
  end

  defp segment_pattern(":" <> name, params) do
    var = Macro.unique_var(:param, __MODULE__)
    {var, [{name, var} | params]}
  end

  defp segment_pattern(literal, params), do: {literal, params}
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
