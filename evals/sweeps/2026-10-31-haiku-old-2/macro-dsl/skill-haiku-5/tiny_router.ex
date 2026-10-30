defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0`
  > and `match/1` in your module. Routes are checked when the module
  > compiles: the path must be a string literal and the handler must be
  > a module name.

  ## Example

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.routes()
      #=> [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{id: "42"}}

      MyApp.Router.match("/missing")
      #=> :error
  """

  @typedoc "One segment of a compiled route: a fixed word or a `:name` parameter."
  @type segment :: {:static, String.t()} | {:param, atom()}

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

  `path` must be a string literal. `handler` must be a module name, such as
  `MyApp.PageHandler`. Anything else raises a `CompileError` at the call site.
  """
  defmacro get(path, handler) do
    {path, handler} = validate_route!(path, handler, __CALLER__)

    quote do
      @tiny_router_routes {unquote(path), unquote(handler)}
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    compiled = Enum.map(routes, fn {path, handler} -> {compile_path(path), handler} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc """
      Returns `{:ok, handler, params}` for the first route that matches `path`,
      or `:error` when none does. Parameter values are strings, keyed by atoms.
      """
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path) when is_binary(path) do
        TinyRouter.match_routes(unquote(Macro.escape(compiled)), path)
      end
    end
  end

  @doc false
  @spec match_routes([{[segment()], module()}], String.t()) ::
          {:ok, module(), %{atom() => String.t()}} | :error
  def match_routes(compiled, path) do
    segments = split(path)

    Enum.find_value(compiled, :error, fn {pattern, handler} ->
      case bind(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp validate_route!(path, handler, caller) do
    if not is_binary(path) do
      compile_error!(caller, "the path must be a string, got: #{Macro.to_string(path)}")
    end

    module = Macro.expand(handler, caller)

    if not module_name?(module) do
      message = "the handler must be a module name, got: #{Macro.to_string(handler)}"
      compile_error!(caller, message)
    end

    {path, module}
  end

  defp module_name?(value), do: is_atom(value) and value not in [nil, true, false]

  defp compile_error!(caller, message) do
    error = [description: "invalid route: " <> message, file: caller.file, line: caller.line]
    raise CompileError, error
  end

  defp compile_path(path) do
    path
    |> split()
    |> Enum.map(&pattern_segment/1)
  end

  defp pattern_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp pattern_segment(word), do: {:static, word}

  defp split(path), do: String.split(path, "/", trim: true)

  defp bind([], [], params), do: {:ok, params}

  defp bind([{:static, word} | pattern], [word | segments], params) do
    bind(pattern, segments, params)
  end

  defp bind([{:param, name} | pattern], [value | segments], params) do
    bind(pattern, segments, Map.put(params, name, value))
  end

  defp bind(_pattern, _segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
