defmodule TinyRouter do
  @moduledoc """
  Declares request routes in a module and matches request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and, when the module compiles,
  > defines `routes/0` and `match/1` in your module. Invalid routes fail the compile.

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
  Declares a route from `path` to `handler`.

  `path` must be a string and `handler` a module name. A path segment that
  starts with `:` captures that part of a request path as a param.
  """
  defmacro get(path, handler) do
    quote do
      TinyRouter.__put_route__(__ENV__, unquote(path), unquote(handler))
    end
  end

  @doc false
  @spec __put_route__(Macro.Env.t(), term(), term()) :: :ok
  def __put_route__(env, path, handler) do
    check_path!(env, path)
    check_handler!(env, handler)
    Module.put_attribute(env.module, :tiny_router_routes, {path, handler})
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    compiled = Enum.map(routes, fn {path, handler} -> {compile_path(path), handler} end)

    quote do
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path) when is_binary(path) do
        segments = String.split(path, "/", trim: true)

        Enum.find_value(unquote(Macro.escape(compiled)), :error, fn {pattern, handler} ->
          case TinyRouter.__match__(segments, pattern) do
            {:ok, params} -> {:ok, handler, params}
            :error -> nil
          end
        end)
      end
    end
  end

  @doc false
  @spec __match__([String.t()], [String.t() | {:param, atom()}]) ::
          {:ok, %{atom() => String.t()}} | :error
  def __match__([], []), do: {:ok, %{}}

  def __match__([literal | segments], [literal | pattern]) when is_binary(literal) do
    __match__(segments, pattern)
  end

  def __match__([value | segments], [{:param, name} | pattern]) do
    case __match__(segments, pattern) do
      {:ok, params} -> {:ok, Map.put(params, name, value)}
      :error -> :error
    end
  end

  def __match__(_segments, _pattern), do: :error

  defp check_path!(_env, path) when is_binary(path), do: :ok

  defp check_path!(env, path) do
    compile_error!(env, "route path must be a string, got: #{inspect(path)}")
  end

  defp check_handler!(_env, handler) when is_atom(handler) and handler not in [nil, true, false],
    do: :ok

  defp check_handler!(env, handler) do
    compile_error!(env, "route handler must be a module name, got: #{inspect(handler)}")
  end

  defp compile_error!(env, description) do
    raise CompileError, description: description, file: env.file, line: env.line
  end

  defp compile_path(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&compile_segment/1)
  end

  # Atoms come from the route source at compile time, never from a request,
  # so creating them here is safe.
  defp compile_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp compile_segment(literal), do: literal
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
