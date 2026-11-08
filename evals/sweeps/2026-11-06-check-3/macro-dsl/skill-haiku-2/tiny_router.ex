defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0`
  > and `match/1` in your module.

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
  Declares a route. `path` must be a string literal and `handler` a module name.

  Invalid arguments stop the compilation of the calling module.
  """
  defmacro get(path, handler) do
    handler_module = Macro.expand_literals(handler, %{__CALLER__ | function: {:call, 2}})

    if not is_binary(path) do
      compile_error!(
        __CALLER__,
        "get/2 expects the path to be a string, such as \"/users/:id\", " <>
          "got: #{Macro.to_string(path)}"
      )
    end

    if not module_name?(handler_module) do
      compile_error!(
        __CALLER__,
        "get/2 expects the handler to be a module name, such as MyApp.UserHandler, " <>
          "got: #{Macro.to_string(handler)}"
      )
    end

    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler_module))
    end
  end

  @doc false
  @spec __define__(module(), String.t(), module()) :: :ok
  def __define__(module, path, handler) do
    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()

    compiled =
      Enum.map(routes, fn {path, handler} ->
        {TinyRouter.Matcher.compile(path), handler}
      end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc "Matches a request path. Returns `{:ok, handler, params}` or `:error`."
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path) when is_binary(path) do
        TinyRouter.Matcher.match(unquote(Macro.escape(compiled)), path)
      end
    end
  end

  defp module_name?(value), do: is_atom(value) and value not in [nil, true, false]

  defp compile_error!(env, description) do
    raise CompileError, description: description, file: env.file, line: env.line
  end
end

defmodule TinyRouter.Matcher do
  @moduledoc false

  @doc false
  @spec compile(String.t()) :: [String.t() | {:param, atom()}]
  def compile(path) do
    path
    |> segments()
    |> Enum.map(&compile_segment/1)
  end

  @doc false
  @spec match([{[String.t() | {:param, atom()}], module()}], String.t()) ::
          {:ok, module(), %{atom() => String.t()}} | :error
  def match(compiled_routes, path) do
    segments = segments(path)

    Enum.find_value(compiled_routes, :error, fn {pattern, handler} ->
      case bind(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp segments(path), do: String.split(path, "/", trim: true)

  defp compile_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp compile_segment(literal), do: literal

  defp bind([], [], params), do: {:ok, params}

  defp bind([{:param, name} | pattern], [segment | segments], params) do
    bind(pattern, segments, Map.put(params, name, segment))
  end

  defp bind([literal | pattern], [literal | segments], params) do
    bind(pattern, segments, params)
  end

  defp bind(_pattern, _segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
