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
  """

  alias TinyRouter.Route

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route for `path` handled by the module `handler`.

  Segments starting with `:` capture the matching part of the request path.
  Raises `ArgumentError` at compile time if `path` is not a string starting
  with `/` or `handler` is not a module name.
  """
  defmacro get(path, handler) do
    # The handler is only stored, never called while compiling, so expand it
    # as if it were used inside a function to avoid a compile-time dependency.
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:match, 1}})

    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  @spec __define__(module(), term(), term()) :: :ok
  def __define__(module, path, handler) do
    route = Route.new!(path, handler)
    Module.put_attribute(module, :tiny_router_routes, route)
  end

  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(:tiny_router_routes)
      |> Enum.reverse()

    declared = Enum.map(routes, &{&1.path, &1.handler})

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(declared))

      @doc """
      Matches a request path against the declared routes.

      Returns `{:ok, handler, params}` for the first matching route, or `:error`.
      """
      @spec match(String.t()) :: {:ok, module(), %{String.t() => String.t()}} | :error
      def match(path) when is_binary(path) do
        Route.match(unquote(Macro.escape(routes)), path)
      end
    end
  end
end

defmodule TinyRouter.Route do
  @moduledoc false

  @enforce_keys [:path, :handler, :segments]
  defstruct [:path, :handler, :segments]

  @type segment :: String.t() | {:param, String.t()}
  @type t :: %__MODULE__{path: String.t(), handler: module(), segments: [segment()]}

  @spec new!(term(), term()) :: t()
  def new!(path, handler) do
    validate_path!(path)
    validate_handler!(handler)
    %__MODULE__{path: path, handler: handler, segments: parse_segments(path)}
  end

  @spec match([t()], String.t()) :: {:ok, module(), map()} | :error
  def match(routes, request_path) do
    request_segments = split(request_path)

    Enum.find_value(routes, :error, fn route ->
      case match_segments(route.segments, request_segments, %{}) do
        {:ok, params} -> {:ok, route.handler, params}
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
          "route handler must be a module name such as MyApp.PageHandler, got: " <>
            inspect(handler)
  end

  defp parse_segments(path) do
    path
    |> split()
    |> Enum.map(&parse_segment/1)
  end

  defp parse_segment(":" <> name), do: {:param, name}
  defp parse_segment(literal), do: literal

  defp split(path), do: String.split(path, "/", trim: true)

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, name} | routes], [value | requests], params) do
    match_segments(routes, requests, Map.put(params, name, value))
  end

  defp match_segments([literal | routes], [literal | requests], params) do
    match_segments(routes, requests, params)
  end

  defp match_segments(_routes, _requests, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
