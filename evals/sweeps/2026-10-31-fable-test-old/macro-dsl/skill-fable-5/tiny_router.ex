defmodule TinyRouter do
  @moduledoc """
  A small DSL (domain-specific language) for declaring routes and matching
  request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` into your module and
  > defines `routes/0` and `match/1` in it once all routes are declared.

  ## Example

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.routes()
      #=> [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{id: "42"}}

      MyApp.Router.match("/missing")
      #=> :error

  Routes are tried in declaration order and the first one that matches wins.
  A segment written as `:name` matches any single request segment and binds
  it under the key `:name` in the params map.
  """

  @typedoc "Path parameters bound from `:name` segments, keyed by the segment name."
  @type params :: %{optional(atom()) => String.t()}

  @typep segment :: String.t() | {:param, atom()}

  defguardp is_module_name(value) when is_atom(value) and value not in [nil, true, false]

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

  `path` must be a string such as `"/"` or `"/users/:id"` and `handler` must be
  a module name. Anything else raises `ArgumentError` while the router module
  compiles.
  """
  defmacro get(path, handler) do
    # Expanding the alias as if inside a function keeps the handler a runtime
    # dependency, so editing a handler does not recompile the router.
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:match, 1}})

    quote do
      TinyRouter.__route__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(:tiny_router_routes)
      |> Enum.reverse()

    matchers = Enum.map(routes, fn {path, handler} -> {compile_path(path), handler} end)

    quote do
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @spec match(String.t()) :: {:ok, module(), TinyRouter.params()} | :error
      def match(request_path) when is_binary(request_path) do
        TinyRouter.__match__(request_path, unquote(Macro.escape(matchers)))
      end
    end
  end

  @doc false
  @spec __route__(module(), String.t(), module()) :: :ok
  def __route__(module, path, handler) when is_binary(path) and is_module_name(handler) do
    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  def __route__(module, path, _handler) when not is_binary(path) do
    raise ArgumentError,
          "#{inspect(module)}: expected a route path to be a string, got: #{inspect(path)}"
  end

  def __route__(module, path, handler) do
    raise ArgumentError,
          "#{inspect(module)}: expected the handler for #{inspect(path)} to be a module name, " <>
            "got: #{inspect(handler)}"
  end

  @doc false
  @spec __match__(String.t(), [{[segment()], module()}]) :: {:ok, module(), params()} | :error
  def __match__(request_path, matchers) do
    find_route(matchers, split_path(request_path))
  end

  defp compile_path(path) do
    path
    |> split_path()
    |> Enum.map(&compile_segment/1)
  end

  # The name comes from a route literal in the router's source, not from
  # request input, so the atom table only grows with the declared routes.
  defp compile_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp compile_segment(literal), do: literal

  defp split_path(path), do: String.split(path, "/", trim: true)

  defp find_route([], _request_segments), do: :error

  defp find_route([{segments, handler} | matchers], request_segments) do
    case bind_params(segments, request_segments, %{}) do
      {:ok, params} -> {:ok, handler, params}
      :error -> find_route(matchers, request_segments)
    end
  end

  defp bind_params([], [], params), do: {:ok, params}

  defp bind_params([{:param, name} | segments], [value | request_segments], params) do
    bind_params(segments, request_segments, Map.put(params, name, value))
  end

  defp bind_params([literal | segments], [literal | request_segments], params) do
    bind_params(segments, request_segments, params)
  end

  defp bind_params(_segments, _request_segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
