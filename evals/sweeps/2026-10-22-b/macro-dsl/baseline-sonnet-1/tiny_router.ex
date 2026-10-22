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

  Routes are validated at compile time. The first matching route wins.
  """

  @param_name ~r/\A[a-z_][a-zA-Z0-9_]*\z/

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route. `path` must be a string starting with `/` and `handler`
  must be a module name.
  """
  defmacro get(path, handler) do
    path = Macro.expand(path, __CALLER__)
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
        {pattern, params} = compile_path(path, env)

        quote do
          defp do_match(unquote(pattern)),
            do: {:ok, unquote(handler), %{unquote_splicing(params)}}
        end
      end

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc """
      Matches a request path. Returns `{:ok, handler, params}` or `:error`.
      """
      @spec match(String.t()) :: {:ok, module(), %{optional(String.t()) => String.t()}} | :error
      def match(path) when is_binary(path), do: do_match(String.split(path, "/", trim: true))
      def match(_path), do: :error

      unquote_splicing(clauses)
      defp do_match(_segments), do: :error
    end
  end

  # Turns "/users/:id" into a list pattern like ["users", id] plus the
  # `{"id", id}` pairs used to build the params map.
  defp compile_path(path, env) do
    {segments, params} =
      path
      |> String.split("/", trim: true)
      |> Enum.map_reduce([], fn
        ":" <> name, acc ->
          var = Macro.var(String.to_atom(name), __MODULE__)

          if List.keymember?(acc, name, 0) do
            compile_error!(env, "duplicate parameter :#{name} in route #{inspect(path)}")
          end

          {var, [{name, var} | acc]}

        literal, acc ->
          {literal, acc}
      end)

    {segments, Enum.reverse(params)}
  end

  defp validate_path!(path, caller) when is_binary(path) do
    unless String.starts_with?(path, "/") do
      compile_error!(caller, "route path must start with \"/\", got: #{inspect(path)}")
    end

    for ":" <> name <- String.split(path, "/", trim: true),
        not Regex.match?(@param_name, name) do
      compile_error!(caller, "invalid parameter name :#{name} in route #{inspect(path)}")
    end

    :ok
  end

  defp validate_path!(other, caller) do
    compile_error!(caller, "route path must be a string, got: #{Macro.to_string(other)}")
  end

  defp validate_handler!(handler, _caller)
       when is_atom(handler) and handler not in [nil, true, false],
       do: :ok

  defp validate_handler!(other, caller) do
    compile_error!(
      caller,
      "route handler must be a module name (e.g. MyApp.PageHandler), got: #{Macro.to_string(other)}"
    )
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
