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

  Routes are tried in declaration order. Empty segments are ignored, so
  `"/users/42/"` matches `"/users/:id"`. Every path must start with `/`
  and a path or handler that is not valid fails at compile time.
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
        {segments, params} = compile_path(path, env)

        quote do
          defp do_match(unquote(segments)) do
            {:ok, unquote(handler), unquote({:%{}, [], params})}
          end
        end
      end

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc """
      Matches a request path, returning `{:ok, handler, params}` or `:error`.
      """
      @spec match(String.t()) :: {:ok, module(), %{optional(String.t()) => String.t()}} | :error
      def match(path) when is_binary(path) do
        path |> String.split("/", trim: true) |> do_match()
      end

      unquote_splicing(clauses)
      defp do_match(_segments), do: :error
    end
  end

  # Turns "/users/:id" into a list pattern (["users", id_var]) and the
  # [{"id", id_var}] entries used to build the params map.
  defp compile_path(path, env) do
    {segments, params} =
      path
      |> String.split("/", trim: true)
      |> Enum.map(fn
        ":" <> name ->
          if name == "" do
            raise_route_error!(env, "route path #{inspect(path)} has a parameter with no name")
          end

          var = Macro.var(String.to_atom("param_" <> name), __MODULE__)
          {var, {name, var}}

        literal ->
          {literal, nil}
      end)
      |> Enum.unzip()

    params = Enum.reject(params, &is_nil/1)
    names = Enum.map(params, &elem(&1, 0))

    if names != Enum.uniq(names) do
      raise_route_error!(env, "route path #{inspect(path)} repeats a parameter name")
    end

    {segments, params}
  end

  defp validate_path!(path, env) when is_binary(path) do
    unless String.starts_with?(path, "/") do
      raise_route_error!(env, "route path must start with \"/\", got: #{inspect(path)}")
    end
  end

  defp validate_path!(path, env) do
    raise_route_error!(
      env,
      "route path must be a string literal, got: #{Macro.to_string(path)}"
    )
  end

  defp validate_handler!(handler, _env)
       when is_atom(handler) and handler not in [nil, true, false],
       do: :ok

  defp validate_handler!(handler, env) do
    raise_route_error!(
      env,
      "route handler must be a module name such as MyApp.PageHandler, " <>
        "got: #{Macro.to_string(handler)}"
    )
  end

  defp raise_route_error!(env, message) do
    raise CompileError, file: env.file, line: env.line, description: "TinyRouter: " <> message
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
