defmodule TinyRouter do
  @moduledoc """
  A small routing DSL (domain-specific language) that maps request paths to
  handler modules.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` into your module and defines
  > `routes/0` and `match/1` there once the module has compiled.

  Declare routes with `get/2`, in the order they should be tried:

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

  A segment that starts with `:` matches any one segment of the request path
  and comes back as a param keyed by its name:

      iex> MyApp.Router.routes()
      [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      iex> MyApp.Router.match("/users/42")
      {:ok, MyApp.UserHandler, %{id: "42"}}

      iex> MyApp.Router.match("/missing")
      :error
  """

  @typedoc "A declared route: the path pattern and the module that handles it."
  @type route :: {String.t(), module()}

  @typedoc "Values captured from `:name` segments, keyed by name."
  @type params :: %{optional(atom()) => String.t()}

  @typedoc false
  @type compiled_route :: {[String.t() | {:param, atom()}], module()}

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route for GET requests.

  `path` must be a string and `handler` a module name such as
  `MyApp.PageHandler`. Anything else raises `ArgumentError` while the router
  module compiles.
  """
  defmacro get(path, handler) do
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:match, 1}})

    quote do
      TinyRouter.__route__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = Enum.reverse(Module.get_attribute(env.module, :tiny_router_routes))
    compiled_routes = Enum.map(routes, &compile_route/1)

    quote do
      @spec routes() :: [TinyRouter.route()]
      def routes, do: unquote(Macro.escape(routes))

      @spec match(String.t()) :: {:ok, module(), TinyRouter.params()} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled_routes)), path)
      end
    end
  end

  @doc false
  @spec __route__(module(), term(), term()) :: :ok
  def __route__(module, path, handler) do
    route = {validate_path!(path), validate_handler!(handler)}
    Module.put_attribute(module, :tiny_router_routes, route)
  end

  @doc false
  @spec __match__([compiled_route()], String.t()) :: {:ok, module(), params()} | :error
  def __match__(compiled_routes, path) do
    first_match(compiled_routes, split_path(path))
  end

  defp validate_path!(path) when is_binary(path), do: path

  defp validate_path!(path) do
    raise ArgumentError, "get/2 expects the path to be a string, got: #{inspect(path)}"
  end

  defp validate_handler!(handler) when is_atom(handler) do
    if Macro.classify_atom(handler) == :alias do
      handler
    else
      raise ArgumentError, handler_message(handler)
    end
  end

  defp validate_handler!(handler), do: raise(ArgumentError, handler_message(handler))

  defp handler_message(handler) do
    "get/2 expects the handler to be a module name such as MyApp.PageHandler, " <>
      "got: #{inspect(handler)}"
  end

  defp compile_route({path, handler}) do
    {Enum.map(split_path(path), &compile_segment/1), handler}
  end

  # Param names are string literals in the router's own source, so the atoms
  # created here are bounded by the code, not by incoming requests.
  defp compile_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp compile_segment(literal), do: literal

  defp split_path(path), do: String.split(path, "/", trim: true)

  defp first_match([], _segments), do: :error

  defp first_match([{pattern, handler} | routes], segments) do
    case bind_params(pattern, segments, %{}) do
      {:ok, params} -> {:ok, handler, params}
      :error -> first_match(routes, segments)
    end
  end

  defp bind_params([], [], params), do: {:ok, params}

  defp bind_params([{:param, name} | pattern], [value | segments], params) do
    bind_params(pattern, segments, Map.put(params, name, value))
  end

  defp bind_params([segment | pattern], [segment | segments], params) do
    bind_params(pattern, segments, params)
  end

  defp bind_params(_pattern, _segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
