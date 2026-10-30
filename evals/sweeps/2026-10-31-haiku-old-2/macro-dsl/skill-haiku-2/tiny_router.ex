defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module with `get/2`, then serves them through `routes/0`
  and `match/1`.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2`, collects the routes you
  > declare, and defines `routes/0` and `match/1` in your module.

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
  Declares a route from `path` to `handler`.

  `path` must be a string and `handler` a module name. Both are checked when
  the module compiles.
  """
  defmacro get(path, handler) do
    quote do
      TinyRouter.__put_route__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(:tiny_router_routes)
      |> Enum.reverse()

    compiled = Enum.map(routes, fn {path, handler} -> {compile_path(path), handler} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc "Finds the handler for a request path. Returns `{:ok, handler, params}` or `:error`."
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
      end
    end
  end

  @doc false
  @spec __put_route__(module(), term(), term()) :: :ok
  def __put_route__(module, path, handler) do
    validate_path!(path)
    validate_handler!(path, handler)
    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  @doc false
  @spec __match__([{[segment()], module()}], String.t()) :: {:ok, module(), map()} | :error
  def __match__(compiled, path) do
    segments = split_path(path)

    Enum.find_value(compiled, :error, fn {pattern, handler} ->
      case bind(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  @typep segment :: {:static, String.t()} | {:param, atom()}

  defp validate_path!(path) when is_binary(path), do: :ok

  defp validate_path!(path) do
    raise ArgumentError, "route path must be a string, got: #{inspect(path)}"
  end

  defp validate_handler!(_path, handler)
       when is_atom(handler) and handler not in [nil, true, false] do
    :ok
  end

  defp validate_handler!(path, handler) do
    raise ArgumentError,
          "handler for route #{inspect(path)} must be a module name, got: #{inspect(handler)}"
  end

  defp compile_path(path) do
    path
    |> split_path()
    |> Enum.map(&compile_segment/1)
  end

  defp compile_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp compile_segment(text), do: {:static, text}

  defp split_path(path), do: String.split(path, "/", trim: true)

  defp bind([], [], params), do: {:ok, params}

  defp bind([{:static, text} | pattern], [text | segments], params) do
    bind(pattern, segments, params)
  end

  defp bind([{:param, key} | pattern], [value | segments], params) do
    bind(pattern, segments, Map.put(params, key, value))
  end

  defp bind(_pattern, _segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
