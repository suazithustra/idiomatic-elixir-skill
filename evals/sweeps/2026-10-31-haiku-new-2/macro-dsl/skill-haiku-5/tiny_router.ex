defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

  `routes/0` returns the declared `{path, handler}` pairs in declaration order.
  `match/1` returns `{:ok, handler, params}` for the first route that matches the
  request path, where `params` maps each `:name` segment to its value, such as
  `%{id: "42"}`, or `:error` when no route matches.

  > #### `use TinyRouter` {: .info}
  >
  > Imports `get/2` and, when the module compiles, defines `routes/0` and `match/1`.
  """

  @doc """
  Declares a route from `path` to `handler`.

  `path` must be a string and `handler` a module name. Anything else fails
  when the module compiles.
  """
  defmacro get(path, handler) do
    path = Macro.expand(path, __CALLER__)
    handler = Macro.expand(handler, __CALLER__)

    check_path!(path, __CALLER__)
    check_handler!(handler, __CALLER__)

    quote do
      @tiny_router_routes {unquote(path), unquote(handler)}
    end
  end

  @doc false
  defmacro __using__(_opts) do
    quote do
      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      import TinyRouter, only: [get: 2]
      @before_compile TinyRouter
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = Enum.reverse(Module.get_attribute(env.module, :tiny_router_routes))
    compiled = Enum.map(routes, fn {path, handler} -> {parse_path(path), handler} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc "Returns `{:ok, handler, params}` for the first matching route, or `:error`."
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path), do: TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
    end
  end

  @doc false
  @spec __match__([{[String.t() | {:param, atom()}], module()}], String.t()) ::
          {:ok, module(), %{atom() => String.t()}} | :error
  def __match__(routes, path) when is_binary(path) do
    segments = String.split(path, "/", trim: true)

    Enum.find_value(routes, :error, fn {pattern, handler} ->
      case bind(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp parse_path(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&parse_segment/1)
  end

  defp parse_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp parse_segment(literal), do: literal

  defp bind([], [], params), do: {:ok, params}

  defp bind([{:param, name} | pattern], [value | segments], params) do
    bind(pattern, segments, Map.put(params, name, value))
  end

  defp bind([literal | pattern], [literal | segments], params) do
    bind(pattern, segments, params)
  end

  defp bind(_pattern, _segments, _params), do: :error

  defp check_path!(path, _env) when is_binary(path), do: :ok

  defp check_path!(path, env) do
    message = "get/2 path must be a string, got: #{Macro.to_string(path)}"
    compile_error!(env, message)
  end

  defp check_handler!(handler, env) do
    if module_name?(handler) do
      :ok
    else
      message = "get/2 handler must be a module name, got: #{Macro.to_string(handler)}"
      compile_error!(env, message)
    end
  end

  defp module_name?(value), do: is_atom(value) and value not in [nil, true, false]

  defp compile_error!(env, message) do
    raise CompileError, file: env.file, line: env.line, description: message
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
