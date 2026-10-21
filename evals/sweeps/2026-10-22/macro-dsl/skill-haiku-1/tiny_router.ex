defmodule TinyRouter do
  @moduledoc """
  Declares request routes in a module and matches request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0` and
  > `match/1` in your module.

  Declarations are checked when the module compiles. A path must be a string,
  and a handler must be a module name such as `MyApp.PageHandler`.

  Path segments that start with `:` capture the matching request segment, so
  `"/users/:id"` matches `"/users/42"` with the params `%{id: "42"}`.

  ## Examples

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.routes()
      #=> [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{id: "42"}}

      MyApp.Router.match("/missing/route")
      #=> :error
  """

  @typedoc "One parsed path segment: a literal string or a named parameter."
  @type segment :: {:static, String.t()} | {:param, atom()}

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route from `path` to `handler`. Routes match in declaration order.
  """
  defmacro get(path, handler) do
    env = __CALLER__
    path_value = Macro.expand(path, env)
    handler_value = Macro.expand(handler, env)

    if not is_binary(path_value) do
      compile_error!(env, "route path must be a string, got: #{Macro.to_string(path)}")
    end

    if not module_name?(handler_value) do
      compile_error!(
        env,
        "route handler must be a module name such as MyApp.PageHandler, " <>
          "got: #{Macro.to_string(handler)}"
      )
    end

    quote do
      TinyRouter.__define__(__MODULE__, unquote(path_value), unquote(handler_value))
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(:tiny_router_routes)
      |> Enum.reverse()

    public_routes = Enum.map(routes, fn {path, handler, _segments} -> {path, handler} end)
    compiled_routes = Enum.map(routes, fn {_path, handler, segments} -> {segments, handler} end)

    quote do
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(public_routes))

      @spec match(String.t()) :: {:ok, module(), map()} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled_routes)), path)
      end
    end
  end

  @doc false
  @spec __define__(module(), String.t(), module()) :: :ok
  def __define__(module, path, handler) do
    Module.put_attribute(module, :tiny_router_routes, {path, handler, parse_segments(path)})
  end

  @doc false
  @spec __match__([{[segment()], module()}], String.t()) :: {:ok, module(), map()} | :error
  def __match__(routes, path) do
    segments = String.split(path, "/", trim: true)

    Enum.find_value(routes, :error, fn {pattern, handler} ->
      case match_segments(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp parse_segments(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&parse_segment/1)
  end

  defp parse_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp parse_segment(static), do: {:static, static}

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:static, same} | pattern], [same | segments], params) do
    match_segments(pattern, segments, params)
  end

  defp match_segments([{:param, name} | pattern], [value | segments], params) do
    match_segments(pattern, segments, Map.put(params, name, value))
  end

  defp match_segments(_pattern, _segments, _params), do: :error

  defp module_name?(value) do
    is_atom(value) and String.starts_with?(Atom.to_string(value), "Elixir.")
  end

  defp compile_error!(env, description) do
    raise CompileError, file: env.file, line: env.line, description: description
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
