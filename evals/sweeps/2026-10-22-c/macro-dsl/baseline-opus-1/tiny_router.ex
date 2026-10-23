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

      MyApp.Router.match("/nope")
      #=> :error

  Routes are compiled into function clauses, so matching is done by the
  BEAM's pattern matcher. Routes are tried in declaration order. Param
  values are returned under string keys, as in Plug and Phoenix.
  """

  @param_name ~r/\A[a-z_][a-zA-Z0-9_]*\z/

  @doc false
  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route from `path` to `handler`.

  `path` must be a string literal starting with `/`. Segments of the form
  `:name` capture that segment into the params map under `"name"`.
  `handler` must be a module name.
  """
  defmacro get(path, handler) do
    path = validate_path!(path, __CALLER__)
    handler = validate_handler!(handler, __CALLER__)
    segments = compile_segments!(path, __CALLER__)

    quote do
      @tiny_router_routes {unquote(path), unquote(handler), unquote(Macro.escape(segments))}
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()

    clauses =
      for {_path, handler, segments} <- routes do
        pattern = Enum.map(segments, &segment_pattern/1)

        params =
          for {:param, name} <- segments do
            {name, Macro.var(String.to_atom(name), __MODULE__)}
          end

        quote do
          defp __match__(unquote(pattern)) do
            {:ok, unquote(handler), %{unquote_splicing(params)}}
          end
        end
      end

    route_pairs = for {path, handler, _segments} <- routes, do: {path, handler}

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      def routes, do: unquote(route_pairs)

      @doc "Matches `path` against the declared routes."
      def match(path) when is_binary(path) do
        path |> String.split("/", trim: true) |> __match__()
      end

      unquote_splicing(clauses)

      defp __match__(_segments), do: :error
    end
  end

  defp segment_pattern({:literal, segment}), do: segment
  defp segment_pattern({:param, name}), do: Macro.var(String.to_atom(name), __MODULE__)

  defp validate_path!("/" <> _ = path, _env), do: path

  defp validate_path!(path, env) when is_binary(path) do
    compile_error!(env, "route path must start with \"/\", got: #{inspect(path)}")
  end

  defp validate_path!(path, env) do
    compile_error!(env, "route path must be a string literal, got: #{Macro.to_string(path)}")
  end

  defp validate_handler!(handler_ast, env) do
    handler = Macro.expand_literals(handler_ast, env)

    if is_atom(handler) and String.starts_with?(Atom.to_string(handler), "Elixir.") do
      handler
    else
      compile_error!(
        env,
        "route handler must be a module name such as MyApp.PageHandler, " <>
          "got: #{Macro.to_string(handler_ast)}"
      )
    end
  end

  defp compile_segments!(path, env) do
    segments =
      path
      |> String.split("/", trim: true)
      |> Enum.map(fn
        ":" <> name ->
          if Regex.match?(@param_name, name) do
            {:param, name}
          else
            compile_error!(env, "invalid param name #{inspect(":" <> name)} in route #{inspect(path)}")
          end

        segment ->
          {:literal, segment}
      end)

    duplicates = for({:param, name} <- segments, do: name) |> then(&(&1 -- Enum.uniq(&1)))

    if duplicates != [] do
      compile_error!(
        env,
        "duplicate param #{inspect(":" <> hd(duplicates))} in route #{inspect(path)}"
      )
    end

    segments
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
