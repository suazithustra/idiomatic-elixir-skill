defmodule TinyRouter do
  @moduledoc """
  A tiny compile-time router.

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

  `use TinyRouter` defines two functions in the calling module:

    * `routes/0` returns the declared `{path, handler}` pairs in declaration order.

    * `match/1` takes a request path and returns `{:ok, handler, params}` for the
      first route that matches, or `:error`. `params` maps the name of each
      `:name` segment, as a string, to the matching part of the request path:

          MyApp.Router.match("/users/42")
          #=> {:ok, MyApp.UserHandler, %{"id" => "42"}}

  Routes are tried in declaration order, so `get "/users/new", ...` must come
  before `get "/users/:id", ...` to take precedence. Empty segments are ignored,
  so `"/users/42/"` also matches `"/users/:id"`.

  A path that is not a string literal, or a handler that is not a module name,
  is a compile error in the router module.
  """

  @typedoc "Values captured from the `:name` segments of a route."
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

  `path` must be a string literal. Each segment is either literal text or a
  `:name` placeholder that matches any single segment. `handler` must be a
  module name such as `MyApp.UserHandler`.
  """
  defmacro get(path, handler) do
    # Expand the alias as if inside a function so the handler becomes a runtime
    # dependency of the router, not a compile-time one.
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:match, 1}})

    unless is_binary(path) do
      compile_error!(
        __CALLER__,
        "expected the route path to be a string, got: #{Macro.to_string(path)}"
      )
    end

    unless module_name?(handler) do
      compile_error!(
        __CALLER__,
        "expected the handler for #{inspect(path)} to be a module name " <>
          "such as MyApp.PageHandler, got: #{Macro.to_string(handler)}"
      )
    end

    quote do
      @tiny_router_routes {unquote(path), unquote(handler)}
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()

    match_clauses =
      for {path, handler} <- routes do
        {segments, params} = compile_path(path)

        quote do
          defp __tiny_router_match__(unquote(segments)),
            do: {:ok, unquote(handler), unquote(params)}
        end
      end

    quote do
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @spec match(String.t()) :: {:ok, module(), TinyRouter.params()} | :error
      def match(path) when is_binary(path) do
        path |> String.split("/", trim: true) |> __tiny_router_match__()
      end

      unquote(match_clauses)
      defp __tiny_router_match__(_segments), do: :error
    end
  end

  # Turns "/users/:id" into the list pattern ["users", id] and the map
  # expression %{"id" => id}.
  defp compile_path(path) do
    {segments, params} =
      path
      |> String.split("/", trim: true)
      |> Enum.map_reduce([], fn
        ":" <> name, acc ->
          var = Macro.var(String.to_atom(name), __MODULE__)
          {var, [{name, var} | acc]}

        literal, acc ->
          {literal, acc}
      end)

    {segments, {:%{}, [], Enum.reverse(params)}}
  end

  defp module_name?(handler) when is_atom(handler),
    do: match?("Elixir." <> _, Atom.to_string(handler))

  defp module_name?(_handler), do: false

  defp compile_error!(env, message) do
    raise CompileError, file: env.file, line: env.line, description: "TinyRouter: " <> message
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
