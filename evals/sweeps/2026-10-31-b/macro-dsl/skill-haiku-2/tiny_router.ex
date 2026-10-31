defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > Imports `get/2` and, when the module compiles, defines `routes/0` and
  > `match/1` in the caller. Nothing else is added to the caller's module.

  ## Example

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{id: "42"}}
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
  Declares a route.

  `path` must be a string literal. `handler` must be a module name, written
  as an alias such as `MyApp.UserHandler`. Anything else fails at compile time.
  """
  defmacro get(path, handler) do
    env = __CALLER__
    handler = Macro.expand_literals(handler, %{env | function: {:call, 2}})

    validate_path!(path, env)
    validate_handler!(handler, env)

    quote do
      TinyRouter.__put_route__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  @spec __put_route__(module(), String.t(), module()) :: :ok
  def __put_route__(module, path, handler) do
    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  @doc false
  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(:tiny_router_routes)
      |> Enum.reverse()

    match_clauses = Enum.map(routes, &match_clause/1)

    quote do
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @spec match(String.t()) :: {:ok, module(), map()} | :error
      def match(path) when is_binary(path) do
        match_segments(String.split(path, "/", trim: true))
      end

      unquote_splicing(match_clauses)

      defp match_segments(_segments), do: :error
    end
  end

  defp validate_path!(path, env) do
    if not is_binary(path) do
      compile_error!(env, "route path must be a string literal, got: #{Macro.to_string(path)}")
    end
  end

  defp validate_handler!(handler, env) do
    valid? = is_atom(handler) and handler not in [nil, true, false]

    if not valid? do
      compile_error!(env, "route handler must be a module name, got: #{Macro.to_string(handler)}")
    end
  end

  defp compile_error!(env, description) do
    raise CompileError, file: env.file, line: env.line, description: description
  end

  defp match_clause({path, handler}) do
    segments = String.split(path, "/", trim: true)
    pattern = Enum.map(segments, &segment_pattern/1)
    params = for ":" <> name <- segments, do: {String.to_atom(name), segment_var(name)}
    params_map = {:%{}, [], params}

    quote do
      defp match_segments(unquote(pattern)) do
        {:ok, unquote(handler), unquote(params_map)}
      end
    end
  end

  defp segment_pattern(":" <> name), do: segment_var(name)
  defp segment_pattern(literal), do: literal

  defp segment_var(name), do: Macro.var(String.to_atom(name), nil)
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
