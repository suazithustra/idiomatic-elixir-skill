defmodule TinyRouter do
  @moduledoc """
  Declares `{path, handler}` routes in a module and matches request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports the `get/2` macro, registers the
  > `:tiny_router_routes` attribute, and defines `routes/0` and `match/1`
  > in your module.

  ## Example

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{id: "42"}}
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route. `path` must be a string literal and `handler` a module name.
  """
  defmacro get(path, handler) do
    path = literal_path!(path, __CALLER__)
    handler = handler_module!(handler, __CALLER__)

    quote do
      Module.put_attribute(__MODULE__, :tiny_router_routes, {unquote(path), unquote(handler)})
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    compiled = Enum.map(routes, fn {path, handler} -> {handler, segments(path)} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc "Matches a request path. The first declared route that fits wins."
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path), do: TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
    end
  end

  @doc false
  @spec __match__([{module(), list()}], String.t()) :: {:ok, module(), map()} | :error
  def __match__(compiled, path) when is_binary(path) do
    segments = split(path)

    Enum.find_value(compiled, :error, fn {handler, pattern} ->
      case bind(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp bind([], [], params), do: {:ok, params}

  defp bind([{:param, name} | pattern], [value | segments], params) do
    bind(pattern, segments, Map.put(params, name, value))
  end

  defp bind([literal | pattern], [literal | segments], params) do
    bind(pattern, segments, params)
  end

  defp bind(_pattern, _segments, _params), do: :error

  defp split(path), do: String.split(path, "/", trim: true)

  defp segments(path), do: path |> split() |> Enum.map(&segment/1)

  defp segment(":" <> name), do: {:param, String.to_atom(name)}
  defp segment(literal), do: literal

  defp literal_path!(path, _env) when is_binary(path), do: path

  defp literal_path!(path, env) do
    compile_error!(env, "route path must be a string literal, got: #{Macro.to_string(path)}")
  end

  defp handler_module!(handler, env) do
    case Macro.expand(handler, env) do
      module when is_atom(module) and module not in [nil, true, false] ->
        module

      _other ->
        compile_error!(env, "handler must be a module name, got: #{Macro.to_string(handler)}")
    end
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
