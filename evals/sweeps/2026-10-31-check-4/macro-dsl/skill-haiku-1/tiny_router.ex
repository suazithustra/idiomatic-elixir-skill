defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2`, registers the
  > `:tiny_router_routes` module attribute, and defines `routes/0` and
  > `match/1` at the end of your module.

  ## Example

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

  Paths are split on `/`, and empty segments are ignored, so `"/users/42/"`
  matches the same route as `"/users/42"`. Parameter names are strings.
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares that requests for `path` are handled by `handler`.

  `path` must be a string and `handler` a module name. Both are checked when
  the enclosing module compiles.
  """
  defmacro get(path, handler) do
    # Expanding the handler as code inside a function keeps it out of the
    # compile-time dependencies: the router only calls it at runtime.
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:call, 2}})

    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
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
  @spec __define__(module(), term(), term()) :: :ok
  def __define__(module, path, handler) do
    check_path!(path)
    check_handler!(handler)

    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  @doc false
  @spec __match__([{String.t(), module()}], term()) :: {:ok, module(), map()} | :error
  def __match__(routes, path) when is_binary(path) do
    segments = split(path)

    Enum.find_value(routes, :error, fn {route, handler} ->
      case match_segments(split(route), segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp check_path!(path) when is_binary(path), do: :ok

  defp check_path!(path) do
    raise ArgumentError, "route path must be a string, got: #{inspect(path)}"
  end

  defp check_handler!(handler) do
    if is_atom(handler) and handler not in [nil, true, false] do
      :ok
    else
      raise ArgumentError, "route handler must be a module name, got: #{inspect(handler)}"
    end
  end

  defp split(path), do: String.split(path, "/", trim: true)

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([":" <> name | expected], [actual | rest], params) do
    match_segments(expected, rest, Map.put(params, name, actual))
  end

  defp match_segments([same | expected], [same | rest], params) do
    match_segments(expected, rest, params)
  end

  defp match_segments(_expected, _rest, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
