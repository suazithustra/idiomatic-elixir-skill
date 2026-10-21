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

  Paths must be string literals starting with `/`, and handlers must be module
  names. Anything else raises a `CompileError` while the router compiles.
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route for `path`, handled by the module `handler`.
  """
  defmacro get(path, handler) do
    path = validate_path!(path, __CALLER__)
    handler = validate_handler!(handler, __CALLER__)

    quote do
      @tiny_router_routes {unquote(path), unquote(handler)}
    end
  end

  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()

    clauses =
      for {path, handler} <- routes do
        {patterns, params} = compile_segments(path)

        quote do
          defp do_match(unquote(patterns)),
            do: {:ok, unquote(handler), %{unquote_splicing(params)}}
        end
      end

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      def routes, do: unquote(Macro.escape(routes))

      @doc "Matches a request path. Returns `{:ok, handler, params}` or `:error`."
      def match(path) when is_binary(path),
        do: do_match(String.split(path, "/", trim: true))

      def match(_path), do: :error

      unquote_splicing(clauses)

      defp do_match(_segments), do: :error
    end
  end

  # Returns the segment patterns for a route and the `{name, var}` pairs for its params.
  defp compile_segments(path) do
    {patterns, params} =
      path
      |> String.split("/", trim: true)
      |> Enum.with_index()
      |> Enum.map_reduce([], fn
        {":" <> name, index}, acc ->
          var = Macro.var(:"param_#{index}", __MODULE__)
          {var, [{name, var} | acc]}

        {literal, _index}, acc ->
          {literal, acc}
      end)

    {patterns, Enum.reverse(params)}
  end

  defp validate_path!(path, env) when is_binary(path) do
    names = for ":" <> name <- String.split(path, "/", trim: true), do: name

    cond do
      not String.starts_with?(path, "/") ->
        compile_error!(env, "route path #{inspect(path)} must start with \"/\"")

      "" in names ->
        compile_error!(env, "route path #{inspect(path)} has a parameter with no name")

      length(names) != length(Enum.uniq(names)) ->
        compile_error!(env, "route path #{inspect(path)} repeats a parameter name")

      true ->
        path
    end
  end

  defp validate_path!(path, env) do
    compile_error!(env, "route path must be a string literal, got: #{Macro.to_string(path)}")
  end

  defp validate_handler!(handler, env) do
    case Macro.expand(handler, env) do
      mod when is_atom(mod) ->
        if match?("Elixir." <> _, Atom.to_string(mod)), do: mod, else: bad_handler!(handler, env)

      _other ->
        bad_handler!(handler, env)
    end
  end

  defp bad_handler!(handler, env) do
    compile_error!(env, "route handler must be a module name, got: #{Macro.to_string(handler)}")
  end

  defp compile_error!(env, message) do
    raise CompileError, file: env.file, line: env.line, description: message
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
