defmodule TinyRouter do
  @moduledoc """
  Declares HTTP-style routes in a module and matches request paths to handlers.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0`
  > and `match/1` in your module. Declare routes with `get/2` in the module body.
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

  `path` must be a string and `handler` must be a module name. Other values
  raise `ArgumentError` when the module compiles.
  """
  defmacro get(path, handler) do
    quote do
      TinyRouter.__put_route__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  @spec __put_route__(module(), term(), term()) :: :ok
  def __put_route__(module, path, handler) do
    if not is_binary(path) do
      raise ArgumentError,
            "#{inspect(module)}: route path must be a string, got: #{inspect(path)}"
    end

    if not module_name?(handler) do
      raise ArgumentError,
            "#{inspect(module)}: handler for #{inspect(path)} must be a module name, " <>
              "got: #{inspect(handler)}"
    end

    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  @doc false
  defmacro __before_compile__(env) do
    # Accumulated attributes come back newest first.
    routes = Enum.reverse(Module.get_attribute(env.module, :tiny_router_routes))

    quote do
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path), do: TinyRouter.__match__(routes(), path)
    end
  end

  @doc false
  @spec __match__([{String.t(), module()}], String.t()) ::
          {:ok, module(), %{atom() => String.t()}} | :error
  def __match__(routes, path) when is_binary(path) do
    segments = split_path(path)

    Enum.find_value(routes, :error, fn {route, handler} ->
      case match_segments(split_path(route), segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp module_name?(value), do: is_atom(value) and value not in [nil, true, false]

  defp split_path(path), do: String.split(path, "/", trim: true)

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([":" <> name | routes], [segment | segments], params) do
    match_segments(routes, segments, Map.put(params, String.to_atom(name), segment))
  end

  defp match_segments([same | routes], [same | segments], params) do
    match_segments(routes, segments, params)
  end

  defp match_segments(_routes, _segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
