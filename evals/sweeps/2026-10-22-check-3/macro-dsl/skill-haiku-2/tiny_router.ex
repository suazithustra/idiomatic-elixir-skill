defmodule TinyRouter do
  @moduledoc """
  Declares path routes in a module and matches request paths to handler modules.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2`, starts collecting routes,
  > and defines `routes/0` and `match/1` in your module.

  ## Example

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{id: "42"}}
  """

  @doc """
  Declares a route from a path to a handler.

  `path` must be a string. `handler` must be a module name, such as
  `MyApp.UserHandler`. Both are checked when the calling module compiles.
  """
  defmacro get(path, handler) do
    env = __CALLER__
    path = Macro.expand(path, env)
    handler = Macro.expand(handler, env)
    validate_route!(path, handler, env)

    quote do
      TinyRouter.__put_route__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = Enum.reverse(Module.get_attribute(env.module, :tiny_router_routes))
    compiled = for {path, handler} <- routes, do: {compile_segments(path), handler}

    quote do
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
      end
    end
  end

  @doc false
  @spec __put_route__(module(), String.t(), module()) :: :ok
  def __put_route__(module, path, handler) do
    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  @doc false
  @spec __match__([{[{:literal, String.t()} | {:param, atom()}], module()}], String.t()) ::
          {:ok, module(), map()} | :error
  def __match__(routes, path) do
    segments = split_path(path)

    Enum.find_value(routes, :error, fn {pattern, handler} ->
      case match_segments(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp validate_route!(path, handler, env) do
    if not is_binary(path) do
      compile_error!(env, "route path must be a string, got: #{Macro.to_string(path)}")
    end

    if not module_name?(handler) do
      compile_error!(env, "route handler must be a module name, got: #{Macro.to_string(handler)}")
    end

    :ok
  end

  defp module_name?(handler) do
    is_atom(handler) and String.starts_with?(Atom.to_string(handler), "Elixir.")
  end

  defp compile_error!(env, description) do
    raise CompileError, file: env.file, line: env.line, description: description
  end

  # Runs at compile time, so the atoms for parameter names are created once.
  defp compile_segments(path) do
    for segment <- split_path(path) do
      case segment do
        ":" <> name -> {:param, String.to_atom(name)}
        _ -> {:literal, segment}
      end
    end
  end

  defp split_path(path), do: String.split(path, "/", trim: true)

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, key} | pattern], [value | segments], params) do
    match_segments(pattern, segments, Map.put(params, key, value))
  end

  defp match_segments([{:literal, segment} | pattern], [segment | segments], params) do
    match_segments(pattern, segments, params)
  end

  defp match_segments(_pattern, _segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
