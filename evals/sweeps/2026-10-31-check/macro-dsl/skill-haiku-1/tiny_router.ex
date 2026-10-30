defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths to them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0` and
  > `match/1` in your module. The routes are checked and compiled when the
  > module is compiled.

  ## Example

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end
  """

  @typedoc false
  @typep segment :: {:static, String.t()} | {:param, atom()}

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

  `path` must be a string literal and `handler` a module name. Any other
  value fails at compile time.
  """
  defmacro get(path, handler) do
    path = expand_path!(path, __CALLER__)
    handler = expand_handler!(handler, __CALLER__)

    quote do
      @tiny_router_routes {unquote(path), unquote(handler)}
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()

    compiled =
      Enum.map(routes, fn {path, handler} ->
        {compile_path(path), handler}
      end)

    quote do
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @spec match(String.t()) :: {:ok, module(), map()} | :error
      def match(path), do: TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
    end
  end

  @doc false
  @spec __match__([{[segment()], module()}], String.t()) :: {:ok, module(), map()} | :error
  def __match__(compiled, path) do
    segments = split(path)

    Enum.find_value(compiled, :error, fn {pattern, handler} ->
      case bind(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp expand_path!(path, env) do
    expanded = Macro.expand(path, env)

    if is_binary(expanded) do
      expanded
    else
      compile_error!(env, "route path must be a string, got: #{Macro.to_string(path)}")
    end
  end

  defp expand_handler!(handler, env) do
    expanded = Macro.expand(handler, env)

    if is_atom(expanded) and expanded not in [nil, true, false] do
      expanded
    else
      compile_error!(env, "route handler must be a module name, got: #{Macro.to_string(handler)}")
    end
  end

  defp compile_error!(env, description) do
    raise CompileError, file: env.file, line: env.line, description: description
  end

  defp compile_path(path) do
    for word <- split(path) do
      case word do
        ":" <> name -> {:param, String.to_atom(name)}
        _ -> {:static, word}
      end
    end
  end

  defp bind([], [], params), do: {:ok, params}

  defp bind([{:static, word} | pattern], [word | segments], params) do
    bind(pattern, segments, params)
  end

  defp bind([{:param, name} | pattern], [value | segments], params) do
    bind(pattern, segments, Map.put(params, name, value))
  end

  defp bind(_pattern, _segments, _params), do: :error

  defp split(path), do: String.split(path, "/", trim: true)
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
