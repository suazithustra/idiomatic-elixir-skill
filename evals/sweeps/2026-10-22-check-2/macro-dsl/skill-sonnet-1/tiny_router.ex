defmodule TinyRouter do
  @moduledoc """
  A small DSL (domain-specific language) for declaring routes.

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

  A path that is not a string starting with `/`, or a handler that is not a
  module name, raises `ArgumentError` when the router module compiles.
  Parameter names are strings in the `params` map, so matching never creates
  atoms from request data.
  """

  @type segment :: String.t() | {:param, String.t()}
  @type params :: %{optional(String.t()) => String.t()}

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route for `path` handled by `handler`.

  Routes are matched in declaration order.
  """
  defmacro get(path, handler) do
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:match, 1}})

    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    compiled = Enum.map(routes, fn {path, handler} -> {parse_path(path), handler} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc """
      Finds the handler for a request path.

      Returns `{:ok, handler, params}` or `:error`.
      """
      @spec match(String.t()) :: {:ok, module(), TinyRouter.params()} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
      end
    end
  end

  @doc false
  @spec __define__(module(), String.t(), module()) :: :ok
  def __define__(module, path, handler) do
    validate_path!(path)
    validate_handler!(handler)
    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  @doc false
  @spec __match__([{[segment()], module()}], String.t()) ::
          {:ok, module(), params()} | :error
  def __match__(routes, path) do
    request_segments = split(path)

    Enum.find_value(routes, :error, fn {segments, handler} ->
      case match_segments(segments, request_segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, name} | segments], [value | rest], params) do
    match_segments(segments, rest, Map.put(params, name, value))
  end

  defp match_segments([literal | segments], [literal | rest], params) when is_binary(literal) do
    match_segments(segments, rest, params)
  end

  defp match_segments(_segments, _request_segments, _params), do: :error

  defp parse_path(path) do
    path
    |> split()
    |> Enum.map(&parse_segment/1)
  end

  defp parse_segment(":" <> name), do: {:param, name}
  defp parse_segment(literal), do: literal

  defp split(path), do: String.split(path, "/", trim: true)

  defp validate_path!("/" <> _rest = path) do
    if Enum.member?(split(path), ":") do
      raise ArgumentError, "route path #{inspect(path)} has a parameter with no name"
    end

    :ok
  end

  defp validate_path!(path) when is_binary(path) do
    raise ArgumentError, "route path must start with \"/\", got: #{inspect(path)}"
  end

  defp validate_path!(path) do
    raise ArgumentError, "route path must be a string, got: #{inspect(path)}"
  end

  defp validate_handler!(handler) when is_atom(handler) and handler not in [nil, true, false],
    do: :ok

  defp validate_handler!(handler) do
    raise ArgumentError, "route handler must be a module name, got: #{inspect(handler)}"
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
