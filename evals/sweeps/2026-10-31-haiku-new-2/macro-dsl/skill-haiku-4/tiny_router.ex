defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > Imports `get/2` into the caller and defines `routes/0` and `match/1`
  > in it. A path that is not a string, a handler that is not a module
  > name, or a `:name` segment that is not a valid name fails when the
  > caller compiles.

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

  @doc false
  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)

      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route from `path` to `handler`. Routes keep their declaration order.

  `path` must be a string. A `:name` segment captures that part of a request
  path into `params` under the atom `name`. `handler` must be a module name,
  such as `MyApp.UserHandler`.
  """
  defmacro get(path, handler) do
    quote do
      TinyRouter.__put_route__(__ENV__, unquote(path), unquote(handler))
    end
  end

  @doc false
  @spec __put_route__(Macro.Env.t(), term(), term()) :: :ok
  def __put_route__(env, path, handler) do
    if not is_binary(path) do
      raise_at(env, "route path must be a string, got: #{inspect(path)}")
    end

    if not module_name?(handler) do
      raise_at(env, "route handler must be a module name, got: #{inspect(handler)}")
    end

    segments = compile_path(env, path)
    Module.put_attribute(env.module, :tiny_router_routes, {path, handler, segments})
  end

  @doc false
  defmacro __before_compile__(env) do
    declared = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    routes = for {path, handler, _segments} <- declared, do: {path, handler}
    matchers = for {_path, handler, segments} <- declared, do: {handler, segments}

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc "Matches a request path. Returns `{:ok, handler, params}` or `:error`."
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(matchers)), path)
      end
    end
  end

  @doc false
  @spec __match__([{module(), [{:literal, String.t()} | {:param, atom()}]}], String.t()) ::
          {:ok, module(), %{atom() => String.t()}} | :error
  def __match__(matchers, path) do
    segments = String.split(path, "/", trim: true)

    Enum.find_value(matchers, :error, fn {handler, pattern} ->
      case bind(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp module_name?(value), do: is_atom(value) and value not in [nil, true, false]

  defp compile_path(env, path) do
    segments =
      for segment <- String.split(path, "/", trim: true) do
        compile_segment(env, path, segment)
      end

    params = for {:param, name} <- segments, do: name

    if Enum.uniq(params) != params do
      raise_at(env, "route #{inspect(path)} uses a parameter name more than once")
    end

    segments
  end

  defp compile_segment(env, path, ":" <> name) do
    if not (name =~ ~r/\A[a-z_][a-zA-Z0-9_]*\z/) do
      raise_at(env, "route #{inspect(path)} has an invalid parameter name :#{name}")
    end

    {:param, String.to_atom(name)}
  end

  defp compile_segment(_env, _path, segment), do: {:literal, segment}

  defp bind([], [], params), do: {:ok, params}

  defp bind([{:literal, text} | pattern], [text | segments], params) do
    bind(pattern, segments, params)
  end

  defp bind([{:param, name} | pattern], [value | segments], params) do
    bind(pattern, segments, Map.put(params, name, value))
  end

  defp bind(_pattern, _segments, _params), do: :error

  defp raise_at(env, message) do
    raise CompileError, file: env.file, line: env.line, description: "TinyRouter: " <> message
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
