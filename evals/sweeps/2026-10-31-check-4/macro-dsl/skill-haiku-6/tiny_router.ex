defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths to them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0` and
  > `match/1` in your module. A bad path or handler stops the compile.

  ## Example

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.match("/users/42")
      # {:ok, MyApp.UserHandler, %{id: "42"}}
  """

  @doc """
  Declares a route. `path` must be a string and `handler` a module name.
  """
  defmacro get(path, handler) do
    env = %{__CALLER__ | function: {:call, 2}}
    path = Macro.expand_literals(path, env)
    handler = Macro.expand_literals(handler, env)
    location = Macro.Env.location(__CALLER__)

    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler), unquote(location))
    end
  end

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()

    compiled =
      Enum.map(routes, fn {path, handler} -> {TinyRouter.Matcher.compile(path), handler} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc "Returns `{:ok, handler, params}` for the first route that matches `path`, or `:error`."
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path) when is_binary(path) do
        TinyRouter.Matcher.match(unquote(Macro.escape(compiled)), path)
      end
    end
  end

  @doc false
  @spec __define__(module(), term(), term(), keyword()) :: :ok
  def __define__(module, path, handler, location) do
    if not is_binary(path) do
      compile_error(location, "path must be a string, got: #{inspect(path)}")
    end

    if not module_name?(handler) do
      compile_error(location, "handler must be a module name, got: #{inspect(handler)}")
    end

    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  defp module_name?(value), do: is_atom(value) and value not in [nil, true, false]

  defp compile_error(location, message) do
    raise CompileError,
      file: location[:file],
      line: location[:line],
      description: "TinyRouter: " <> message
  end
end

defmodule TinyRouter.Matcher do
  @moduledoc false

  @type segment :: {:literal, String.t()} | {:param, atom()}

  @doc false
  @spec compile(String.t()) :: [segment()]
  def compile(path), do: Enum.map(segments(path), &compile_segment/1)

  @doc false
  @spec match([{[segment()], module()}], String.t()) :: {:ok, module(), map()} | :error
  def match(routes, path) do
    request = segments(path)

    Enum.find_value(routes, :error, fn {pattern, handler} ->
      case match_segments(pattern, request, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp segments(path), do: String.split(path, "/", trim: true)

  defp compile_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp compile_segment(literal), do: {:literal, literal}

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:literal, segment} | pattern], [segment | request], params) do
    match_segments(pattern, request, params)
  end

  defp match_segments([{:param, name} | pattern], [value | request], params) do
    match_segments(pattern, request, Map.put(params, name, value))
  end

  defp match_segments(_pattern, _request, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
