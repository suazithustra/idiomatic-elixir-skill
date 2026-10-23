defmodule TinyRouter do
  @moduledoc """
  A tiny compile-time router.

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.routes()
      #=> [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{"id" => "42"}}

  A path that is not a string, or a handler that is not a module name,
  raises `ArgumentError` when the router module compiles.
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc "Declares a route for `path` served by the module `handler`."
  defmacro get(path, handler) do
    path = validate_path!(path)
    handler = validate_handler!(handler, __CALLER__)

    quote do
      @tiny_router_routes {unquote(path), unquote(handler)}
    end
  end

  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()

    clauses =
      for {path, handler} <- routes do
        {pattern, params} = compile_path(path)

        quote do
          defp do_match(unquote(pattern)), do: {:ok, unquote(handler), %{unquote_splicing(params)}}
        end
      end

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      def routes, do: unquote(Macro.escape(routes))

      @doc "Matches a request path, returning `{:ok, handler, params}` or `:error`."
      def match(path) when is_binary(path), do: do_match(String.split(path, "/", trim: true))
      def match(_other), do: :error

      unquote_splicing(clauses)
      defp do_match(_segments), do: :error
    end
  end

  defp compile_path(path) do
    {segments, params} =
      path
      |> String.split("/", trim: true)
      |> Enum.map_reduce([], fn
        ":" <> name, params ->
          var = Macro.var(String.to_atom("param_" <> name), __MODULE__)
          {var, [{name, var} | params]}

        literal, params ->
          {literal, params}
      end)

    {segments, Enum.reverse(params)}
  end

  defp validate_path!(path) when is_binary(path) do
    unless String.starts_with?(path, "/") do
      raise ArgumentError, "route path must start with \"/\", got: #{inspect(path)}"
    end

    names = for ":" <> name <- String.split(path, "/", trim: true), do: name

    if "" in names or names != Enum.uniq(names) do
      raise ArgumentError, "route path has an empty or duplicate :param: #{inspect(path)}"
    end

    path
  end

  defp validate_path!(other) do
    raise ArgumentError, "route path must be a string, got: #{Macro.to_string(other)}"
  end

  defp validate_handler!(handler, caller) do
    case Macro.expand(handler, caller) do
      mod when is_atom(mod) and mod not in [nil, true, false] ->
        mod

      _ ->
        raise ArgumentError,
              "route handler must be a module name, got: #{Macro.to_string(handler)}"
    end
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
