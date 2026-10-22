defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2`, registers the
  > `:tiny_router_routes` attribute, and defines `routes/0` and `match/1`
  > in your module. Routes are checked when the module compiles.

  Segments that start with `:` capture the request segment under that name.
  Routes are tried in declaration order and the first match wins.

  ## Examples

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.routes()
      #=> [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{"id" => "42"}}

      MyApp.Router.match("/missing")
      #=> :error
  """

  @doc """
  Declares a route that sends requests for `path` to `handler`.

  `path` must be a string and `handler` a module name. Anything else raises
  `ArgumentError` when the enclosing module compiles.
  """
  defmacro get(path, handler) do
    quote do
      TinyRouter.__put_route__(__MODULE__, unquote(path), unquote(handler))
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

    quote do
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @spec match(String.t()) :: {:ok, module(), %{String.t() => String.t()}} | :error
      def match(path), do: TinyRouter.__match__(routes(), path)
    end
  end

  @doc false
  @spec __put_route__(module(), String.t(), module()) :: :ok
  def __put_route__(module, path, handler) do
    if not is_binary(path) do
      raise ArgumentError,
            "#{inspect(module)}: route path must be a string, got: #{inspect(path)}"
    end

    if not is_atom(handler) or handler in [nil, true, false] do
      raise ArgumentError,
            "#{inspect(module)}: route handler must be a module name, got: #{inspect(handler)}"
    end

    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  @doc false
  @spec __match__([{String.t(), module()}], String.t()) ::
          {:ok, module(), %{String.t() => String.t()}} | :error
  def __match__(routes, path) when is_binary(path) do
    segments = split_path(path)
    Enum.find_value(routes, :error, &match_route(&1, segments))
  end

  defp match_route({route, handler}, segments) do
    case match_segments(split_path(route), segments, %{}) do
      {:ok, params} -> {:ok, handler, params}
      # nil tells Enum.find_value/3 to keep looking at the next route
      :error -> nil
    end
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([":" <> name | routes], [segment | segments], params) do
    match_segments(routes, segments, Map.put(params, name, segment))
  end

  defp match_segments([segment | routes], [segment | segments], params) do
    match_segments(routes, segments, params)
  end

  defp match_segments(_routes, _segments, _params), do: :error

  defp split_path(path), do: String.split(path, "/", trim: true)
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
