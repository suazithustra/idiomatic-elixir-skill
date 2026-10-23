defmodule TinyRouter do
  @moduledoc """
  A tiny compile-time router DSL.

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.routes()
      #=> [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{"id" => "42"}}
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc "Declares a route for `path` handled by the module `handler`."
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
          defp do_match(unquote(pattern)), do: {:ok, unquote(handler), unquote({:%{}, [], params})}
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

  defp compile_path(path) do
    {pattern, params} =
      path
      |> String.split("/", trim: true)
      |> Enum.with_index()
      |> Enum.map_reduce([], fn
        {":" <> name, i}, acc ->
          var = Macro.var(:"param_#{i}", __MODULE__)
          {var, [{name, var} | acc]}

        {segment, _i}, acc ->
          {segment, acc}
      end)

    {pattern, Enum.reverse(params)}
  end

  defp validate_path!(path, caller) when is_binary(path) do
    unless String.starts_with?(path, "/") do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description: "TinyRouter: route path must start with \"/\", got: #{inspect(path)}"
    end
  end

  defp validate_path!(path, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description:
        "TinyRouter: route path must be a string literal, got: #{Macro.to_string(path)}"
  end

  defp validate_handler!(handler, caller) do
    if not (is_atom(handler) and String.starts_with?(Atom.to_string(handler), "Elixir.")) do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description:
          "TinyRouter: route handler must be a module name (e.g. MyApp.Handler), got: " <>
            Macro.to_string(handler)
    end
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
