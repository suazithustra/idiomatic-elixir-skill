defmodule TinyRouter do
  @moduledoc """
  A small DSL (domain-specific language) for declaring routes and matching request paths.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0` and
  > `match/1` in your module.

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

      MyApp.Router.match("/nope")
      #=> :error

  Routes are tried in declaration order, and the first match wins. A path or
  handler of the wrong type raises `ArgumentError` when the router module
  compiles. Parameter names in `params` are strings.
  """

  @typedoc "A route path pattern such as `\"/users/:id\"`."
  @type path :: String.t()

  @typedoc "A path pattern split into literal segments and `{:param, name}` segments."
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
  Declares a route that sends `path` to `handler`.

  `path` must be a string starting with `/`. Segments starting with `:` capture
  the matching part of the request path. `handler` must be a module name.
  """
  defmacro get(path, handler) do
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

    quote do
      @spec routes() :: [{TinyRouter.path(), module()}]
      def routes, do: unquote(Macro.escape(declared))

      @spec match(String.t()) :: {:ok, module(), %{optional(String.t()) => String.t()}} | :error
      def match(request_path) when is_binary(request_path) do
        TinyRouter.__match__(unquote(Macro.escape(routes)), request_path)
      end
    end
  end

  @doc false
  @spec __define__(module(), term(), term()) :: :ok
  def __define__(module, path, handler) do
    validate_path!(path)
    validate_handler!(handler)
    Module.put_attribute(module, :tiny_router_routes, {path, handler, segments(path)})
  end

  @doc false
  @spec __match__([{path(), module(), [segment()]}], String.t()) ::
          {:ok, module(), %{optional(String.t()) => String.t()}} | :error
  def __match__(routes, request_path) do
    request_segments = segments(request_path)

    Enum.find_value(routes, :error, fn {_path, handler, route_segments} ->
      case match_segments(route_segments, request_segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp validate_path!("/" <> _rest), do: :ok

  defp validate_path!(path) when is_binary(path) do
    raise ArgumentError, "route path must start with \"/\", got: #{inspect(path)}"
  end

  defp validate_path!(path) do
    raise ArgumentError, "route path must be a string, got: #{inspect(path)}"
  end

  defp validate_handler!(handler) when is_atom(handler) and handler not in [nil, true, false] do
    :ok
  end

  defp validate_handler!(handler) do
    raise ArgumentError,
          "route handler must be a module name such as MyApp.PageHandler, got: #{inspect(handler)}"
  end

  defp segments(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&segment/1)
  end

  defp segment(":" <> name), do: {:param, name}
  defp segment(literal), do: literal

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, name} | routes], [value | requests], params) do
    match_segments(routes, requests, Map.put(params, name, value))
  end

  defp match_segments([literal | routes], [literal | requests], params) when is_binary(literal) do
    match_segments(routes, requests, params)
  end

  defp match_segments(_routes, _requests, _params), do: :error
end

defmodule MyApp.PageHandler do
  @moduledoc false
end

defmodule MyApp.UserHandler do
  @moduledoc false
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
