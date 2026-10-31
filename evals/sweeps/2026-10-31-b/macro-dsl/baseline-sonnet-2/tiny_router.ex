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

  The path must be a string literal and the handler a module name. Anything
  else raises a `CompileError` when the router module compiles.
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
    path = validate_path!(path, __CALLER__)
    handler = validate_handler!(handler, __CALLER__)
    segments = compile_segments!(path, __CALLER__)

    quote do
      @tiny_router_routes {unquote(path), unquote(handler), unquote(Macro.escape(segments))}
    end
  end

  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()

    declared = for {path, handler, _segments} <- routes, do: {path, handler}

    clauses =
      for {_path, handler, segments} <- routes do
        {patterns, params} = build_pattern(segments)

        quote do
          defp do_match(unquote(patterns)),
            do: {:ok, unquote(handler), %{unquote_splicing(params)}}
        end
      end

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(declared))

      @doc "Matches a request path, returning `{:ok, handler, params}` or `:error`."
      @spec match(String.t()) :: {:ok, module(), %{optional(String.t()) => String.t()}} | :error
      def match(path) when is_binary(path), do: do_match(String.split(path, "/", trim: true))

      unquote_splicing(clauses)
      defp do_match(_segments), do: :error
    end
  end

  defp validate_path!(path, _env) when is_binary(path), do: path

  defp validate_path!(other, env) do
    compile_error!(env, "route path must be a string literal, got: #{Macro.to_string(other)}")
  end

  defp validate_handler!(handler, env) do
    case Macro.expand(handler, env) do
      mod when is_atom(mod) and mod not in [nil, true, false] ->
        mod

      _ ->
        compile_error!(
          env,
          "route handler must be a module name, got: #{Macro.to_string(handler)}"
        )
    end
  end

  defp compile_segments!(path, env) do
    unless String.starts_with?(path, "/") do
      compile_error!(env, "route path must start with \"/\", got: #{inspect(path)}")
    end

    segments =
      path
      |> String.split("/", trim: true)
      |> Enum.map(fn
        ":" -> compile_error!(env, "empty parameter name in path #{inspect(path)}")
        ":" <> name -> {:param, name}
        literal -> {:literal, literal}
      end)

    names = for {:param, name} <- segments, do: name

    if names != Enum.uniq(names) do
      compile_error!(env, "duplicate parameter name in path #{inspect(path)}")
    end

    segments
  end

  defp build_pattern(segments) do
    {patterns, params} =
      segments
      |> Enum.map(fn
        {:literal, literal} ->
          {literal, nil}

        {:param, name} ->
          var = Macro.var(String.to_atom("param_" <> name), __MODULE__)
          {var, {name, var}}
      end)
      |> Enum.unzip()

    {patterns, Enum.reject(params, &is_nil/1)}
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
