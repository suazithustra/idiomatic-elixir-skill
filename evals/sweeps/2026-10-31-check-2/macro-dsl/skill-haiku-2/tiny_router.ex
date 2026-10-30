defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > Imports `get/2` into the caller and sets up `routes/0` and `match/1`
  > when the module compiles. Nothing else is added to the caller's API.

  Each `get/2` call declares one route. A segment written as `:name` matches
  any value, and the value is returned in `params` under the atom key `:name`.

  An invalid declaration raises `ArgumentError` when the router module compiles.
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
  """
  defmacro get(path, handler) do
    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    public_routes = for {path, handler, _segments} <- routes, do: {path, handler}
    compiled_routes = for {_path, handler, segments} <- routes, do: {handler, segments}

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(public_routes))

      @doc "Matches `path` against the declared routes, returning the first match."
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled_routes)), path)
      end
    end
  end

  @doc false
  @spec __define__(module(), term(), term()) :: :ok
  def __define__(module, path, handler) do
    check_path!(path)
    check_handler!(path, handler)

    Module.put_attribute(module, :tiny_router_routes, {path, handler, compile_segments(path)})
  end

  @doc false
  @spec __match__([{module(), [tuple()]}], String.t()) :: {:ok, module(), map()} | :error
  def __match__(compiled_routes, path) do
    segments = split_path(path)

    Enum.find_value(compiled_routes, :error, fn {handler, route_segments} ->
      case match_segments(route_segments, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp check_path!(path) when is_binary(path), do: :ok

  defp check_path!(path) do
    raise ArgumentError, "route path must be a string, got: #{inspect(path)}"
  end

  defp check_handler!(_path, handler) when is_atom(handler) and handler not in [nil, true, false],
    do: :ok

  defp check_handler!(path, handler) do
    raise ArgumentError,
          "handler for route #{inspect(path)} must be a module name, got: #{inspect(handler)}"
  end

  defp compile_segments(path) do
    for segment <- split_path(path) do
      case segment do
        ":" <> name -> {:param, String.to_atom(name)}
        literal -> {:literal, literal}
      end
    end
  end

  defp split_path(path), do: String.split(path, "/", trim: true)

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:literal, segment} | route], [segment | segments], params) do
    match_segments(route, segments, params)
  end

  defp match_segments([{:param, name} | route], [value | segments], params) do
    match_segments(route, segments, Map.put(params, name, value))
  end

  defp match_segments(_route, _segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
