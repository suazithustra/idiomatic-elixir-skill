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

  Segments starting with `:` capture the corresponding request segment into
  the params map, keyed by the segment name as a string. Routes are tried in
  declaration order.
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
  Declares a route from `path` to `handler`.

  `path` must be a string literal and `handler` a module name; anything else
  raises a `CompileError` when the router module is compiled.
  """
  defmacro get(path, handler) do
    path = validate_path!(path, __CALLER__)
    handler = validate_handler!(handler, __CALLER__)
    segments = parse_segments!(path, __CALLER__)

    quote do
      @tiny_router_routes {unquote(path), unquote(handler), unquote(Macro.escape(segments))}
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    pairs = for {path, handler, _segments} <- routes, do: {path, handler}
    clauses = Enum.map(routes, &match_clause/1)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(pairs))

      @doc "Matches a request path, returning `{:ok, handler, params}` or `:error`."
      @spec match(String.t()) :: {:ok, module(), %{String.t() => String.t()}} | :error
      def match(path) when is_binary(path) do
        path |> String.split("/", trim: true) |> __tiny_router_match__()
      end

      unquote_splicing(clauses)
      defp __tiny_router_match__(_segments), do: :error
    end
  end

  defp match_clause({_path, handler, segments}) do
    pattern =
      Enum.map(segments, fn
        {:param, name} -> Macro.var(String.to_atom(name), __MODULE__)
        {:static, value} -> value
      end)

    params =
      for {:param, name} <- segments do
        {name, Macro.var(String.to_atom(name), __MODULE__)}
      end

    quote do
      defp __tiny_router_match__(unquote(pattern)) do
        {:ok, unquote(handler), %{unquote_splicing(params)}}
      end
    end
  end

  defp validate_path!(path, _env) when is_binary(path), do: path

  defp validate_path!(path, env) do
    compile_error!(env, "route path must be a string literal, got: #{Macro.to_string(path)}")
  end

  defp validate_handler!(handler, env) do
    expanded = Macro.expand(handler, env)

    if is_atom(expanded) and String.starts_with?(Atom.to_string(expanded), "Elixir.") do
      expanded
    else
      compile_error!(env, "route handler must be a module name, got: #{Macro.to_string(handler)}")
    end
  end

  defp parse_segments!(path, env) do
    segments =
      path
      |> String.split("/", trim: true)
      |> Enum.map(fn
        ":" <> "" -> compile_error!(env, "route #{inspect(path)} has a parameter with no name")
        ":" <> name -> {:param, name}
        static -> {:static, static}
      end)

    names = for {:param, name} <- segments, do: name

    case names -- Enum.uniq(names) do
      [] -> segments
      [dup | _] -> compile_error!(env, "route #{inspect(path)} repeats parameter :#{dup}")
    end
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
