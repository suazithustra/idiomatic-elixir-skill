defmodule TinyRouter do
  @moduledoc """
  A small DSL (domain-specific language) for declaring routes.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines
  > `routes/0` and `match/1` in your module.

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

  A route path that is not a string, or a handler that is not a module
  name, raises `ArgumentError` when the router module compiles.
  """

  @type segment :: String.t() | {:param, String.t()}

  @doc false
  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)

      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route. A path segment that starts with `:` is a parameter.
  """
  defmacro get(path, handler) do
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:match, 1}})

    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(:tiny_router_routes)
      |> Enum.reverse()

    table = Enum.map(routes, &compile_route/1)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc """
      Finds the handler for a request path.

      Returns `{:ok, handler, params}`, where `params` maps parameter
      names to the matching path segments, or `:error`.
      """
      @spec match(String.t()) :: {:ok, module(), %{String.t() => String.t()}} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(table)), path)
      end
    end
  end

  @doc false
  @spec __define__(module(), String.t(), module()) :: :ok
  def __define__(module, path, handler)
      when is_binary(path) and is_atom(handler) and handler not in [nil, true, false] do
    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  def __define__(_module, path, _handler) when not is_binary(path) do
    raise ArgumentError, "route path must be a string, got: #{inspect(path)}"
  end

  def __define__(_module, _path, handler) do
    raise ArgumentError, "route handler must be a module name, got: #{inspect(handler)}"
  end

  @doc false
  @spec __match__([{[segment()], module()}], String.t()) ::
          {:ok, module(), %{String.t() => String.t()}} | :error
  def __match__(table, path) do
    segments = split(path)

    Enum.find_value(table, :error, fn route -> match_route(route, segments) end)
  end

  defp compile_route({path, handler}) do
    {path |> split() |> Enum.map(&parse_segment/1), handler}
  end

  defp split(path), do: String.split(path, "/", trim: true)

  defp parse_segment(":" <> name), do: {:param, name}
  defp parse_segment(literal), do: literal

  defp match_route({pattern, handler}, segments) do
    case match_segments(pattern, segments, %{}) do
      {:ok, params} -> {:ok, handler, params}
      :error -> nil
    end
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, name} | pattern], [value | segments], params) do
    match_segments(pattern, segments, Map.put(params, name, value))
  end

  defp match_segments([segment | pattern], [segment | segments], params)
       when is_binary(segment) do
    match_segments(pattern, segments, params)
  end

  defp match_segments(_pattern, _segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
