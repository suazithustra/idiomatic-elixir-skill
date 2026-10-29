defmodule TinyRouter do
  @moduledoc """
  A small DSL (domain-specific language) for declaring routes and matching
  request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0`
  > and `match/1` in your module.

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

      MyApp.Router.match("/nope")
      #=> :error

  Routes are tried in declaration order and the first match wins. A path
  that is not a string, or a handler that is not a module name, raises
  `ArgumentError` when the router module compiles.
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

  Segments that start with `:` capture the request segment in that position.
  """
  defmacro get(path, handler) do
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:match, 1}})
    :ok = validate_route!(path, handler)

    quote do
      @tiny_router_routes {unquote(path), unquote(handler)}
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(:tiny_router_routes)
      |> Enum.reverse()

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc """
      Matches a request path against the declared routes.

      Returns `{:ok, handler, params}`, or `:error` when no route matches.
      """
      @spec match(String.t()) :: {:ok, module(), %{String.t() => String.t()}} | :error
      def match(path), do: TinyRouter.__match__(routes(), path)
    end
  end

  @doc false
  @spec __match__([{String.t(), module()}], String.t()) ::
          {:ok, module(), %{String.t() => String.t()}} | :error
  def __match__(routes, path) when is_binary(path) do
    segments = split(path)

    Enum.find_value(routes, :error, fn route -> match_route(route, segments) end)
  end

  defp validate_route!(path, _handler) when not is_binary(path) do
    raise ArgumentError,
          "route path must be a string literal, got: #{Macro.to_string(path)}"
  end

  defp validate_route!(_path, handler)
       when is_atom(handler) and handler not in [nil, true, false] do
    :ok
  end

  defp validate_route!(_path, handler) do
    raise ArgumentError,
          "route handler must be a module name, got: #{Macro.to_string(handler)}"
  end

  defp match_route({pattern, handler}, segments) do
    case match_segments(split(pattern), segments, %{}) do
      {:ok, params} -> {:ok, handler, params}
      :error -> nil
    end
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([":" <> name | pattern], [value | segments], params) do
    match_segments(pattern, segments, Map.put(params, name, value))
  end

  defp match_segments([segment | pattern], [segment | segments], params) do
    match_segments(pattern, segments, params)
  end

  defp match_segments(_pattern, _segments, _params), do: :error

  defp split(path), do: String.split(path, "/", trim: true)
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
