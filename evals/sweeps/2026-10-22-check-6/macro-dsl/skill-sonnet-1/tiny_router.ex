defmodule TinyRouter do
  @moduledoc """
  A tiny DSL for declaring routes and matching request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports the `get/2` macro and defines
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

  A path that is not a string, or a handler that is not a module name, raises
  an `ArgumentError` when the router module is compiled.
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
  Declares a route sending `path` to `handler`.

  Segments starting with `:` capture the matching part of the request path.
  """
  defmacro get(path, handler) do
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:routes, 0}})

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

    declared = Enum.map(routes, fn {path, handler, _segments} -> {path, handler} end)
    compiled = Enum.map(routes, fn {_path, handler, segments} -> {segments, handler} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(declared))

      @doc "Matches a request path against the declared routes."
      @spec match(String.t()) :: {:ok, module(), %{String.t() => String.t()}} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
      end
    end
  end

  @doc false
  @spec __define__(module(), term(), term()) :: :ok
  def __define__(module, path, handler) when is_binary(path) and is_atom(handler) do
    if handler in [nil, true, false] do
      raise ArgumentError, "route handler must be a module name, got: #{inspect(handler)}"
    end

    Module.put_attribute(module, :tiny_router_routes, {path, handler, split(path)})
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
  def __match__(routes, path) do
    request_segments = split(path)

    Enum.find_value(routes, :error, fn {route_segments, handler} ->
      case match_segments(route_segments, request_segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, name} | route_rest], [value | request_rest], params) do
    match_segments(route_rest, request_rest, Map.put(params, name, value))
  end

  defp match_segments([segment | route_rest], [segment | request_rest], params) do
    match_segments(route_rest, request_rest, params)
  end

  defp match_segments(_route_segments, _request_segments, _params), do: :error

  defp split(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&parse_segment/1)
  end

  defp parse_segment(":" <> name), do: {:param, name}
  defp parse_segment(segment), do: segment
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
