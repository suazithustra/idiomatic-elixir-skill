defmodule TinyRouter do
  @moduledoc """
  A small compile-time router DSL.

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.routes()
      #=> [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{"id" => "42"}}

      MyApp.Router.match("/nope")
      #=> :error

  Paths must be string literals starting with `/`, and handlers must be module
  names (aliases). Anything else raises an `ArgumentError` while the router
  module compiles. Matching is done by function clauses generated at compile
  time, so routes are matched in declaration order.
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route for `path` handled by the module `handler`.
  """
  defmacro get(path, handler) do
    handler = Macro.expand(handler, __CALLER__)
    validate_path!(path, __CALLER__)
    validate_handler!(handler, __CALLER__)

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
          defp do_match(unquote(pattern)),
            do: {:ok, unquote(handler), %{unquote_splicing(params)}}
        end
      end

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      def routes, do: unquote(Macro.escape(routes))

      @doc "Matches a request path, returning `{:ok, handler, params}` or `:error`."
      def match(path) when is_binary(path), do: do_match(String.split(path, "/", trim: true))
      def match(_path), do: :error

      unquote_splicing(clauses)
      defp do_match(_segments), do: :error
    end
  end

  defp validate_path!(path, caller) when is_binary(path) do
    unless String.starts_with?(path, "/") do
      raise ArgumentError,
            "#{location(caller)}route path must start with \"/\", got: #{inspect(path)}"
    end

    names = for ":" <> name <- split(path), do: name

    if "" in names do
      raise ArgumentError,
            "#{location(caller)}route path #{inspect(path)} has a \":\" segment with no name"
    end

    if names != Enum.uniq(names) do
      raise ArgumentError,
            "#{location(caller)}route path #{inspect(path)} repeats a parameter name"
    end
  end

  defp validate_path!(path, caller) do
    raise ArgumentError,
          "#{location(caller)}route path must be a string literal, got: #{Macro.to_string(path)}"
  end

  defp validate_handler!(handler, _caller)
       when is_atom(handler) and handler not in [nil, true, false],
       do: :ok

  defp validate_handler!(handler, caller) do
    raise ArgumentError,
          "#{location(caller)}route handler must be a module name, got: #{Macro.to_string(handler)}"
  end

  defp location(caller), do: "#{Path.relative_to_cwd(caller.file)}:#{caller.line}: "

  defp split(path), do: String.split(path, "/", trim: true)

  # Turns "/users/:id" into a list pattern like ["users", id_var] plus the
  # `{"id", id_var}` pairs used to build the params map.
  defp compile_path(path) do
    {pattern, params} =
      path
      |> split()
      |> Enum.map_reduce([], fn
        ":" <> name, acc ->
          var = Macro.var(String.to_atom("param_" <> name), __MODULE__)
          {var, [{name, var} | acc]}

        literal, acc ->
          {literal, acc}
      end)

    {pattern, Enum.reverse(params)}
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
