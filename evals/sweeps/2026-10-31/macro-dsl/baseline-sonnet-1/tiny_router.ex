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

  Routes are tried in declaration order. Param names in the returned map are
  strings.
  """

  @doc false
  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route for `path` handled by `handler`.

  Raises `CompileError` if `path` is not a string literal starting with `/`,
  or if `handler` is not a module name.
  """
  defmacro get(path, handler) do
    path = validate_path!(path, __CALLER__)
    handler = validate_handler!(handler, __CALLER__)

    quote do
      @tiny_router_routes {unquote(path), unquote(handler)}
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()

    clauses =
      for {path, handler} <- routes do
        {pattern, params} = compile_segments(path, env)

        quote do
          defp do_match(unquote(pattern)), do: {:ok, unquote(handler), %{unquote_splicing(params)}}
        end
      end

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc """
      Matches a request path, returning `{:ok, handler, params}` or `:error`.
      """
      @spec match(term()) :: {:ok, module(), %{optional(String.t()) => String.t()}} | :error
      def match(path) when is_binary(path), do: do_match(TinyRouter.split(path))
      def match(_path), do: :error

      unquote_splicing(clauses)
      defp do_match(_segments), do: :error
    end
  end

  @doc false
  def split(path), do: String.split(path, "/", trim: true)

  # Builds the function-head pattern for a route and the `{name, var}` pairs
  # used to construct the params map.
  defp compile_segments(path, env) do
    {patterns, params} =
      path
      |> split()
      |> Enum.with_index()
      |> Enum.map_reduce([], fn
        {":" <> name, index}, acc ->
          if List.keymember?(acc, name, 0) do
            raise CompileError,
              file: env.file,
              line: env.line,
              description: "tiny_router: duplicate param #{inspect(name)} in #{inspect(path)}"
          end

          var = Macro.var(:"param_#{index}", __MODULE__)
          {var, [{name, var} | acc]}

        {literal, _index}, acc ->
          {literal, acc}
      end)

    {patterns, Enum.reverse(params)}
  end

  defp validate_path!(path, caller) when is_binary(path) do
    if String.starts_with?(path, "/") do
      path
    else
      compile_error!(caller, "route path must start with \"/\", got: #{inspect(path)}")
    end
  end

  defp validate_path!(other, caller) do
    compile_error!(caller, "route path must be a string, got: #{Macro.to_string(other)}")
  end

  defp validate_handler!(handler, caller) do
    case Macro.expand(handler, caller) do
      mod when is_atom(mod) and mod not in [nil, true, false] ->
        mod

      _ ->
        compile_error!(
          caller,
          "route handler must be a module name, got: #{Macro.to_string(handler)}"
        )
    end
  end

  defp compile_error!(caller, message) do
    raise CompileError, file: caller.file, line: caller.line, description: "tiny_router: " <> message
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
