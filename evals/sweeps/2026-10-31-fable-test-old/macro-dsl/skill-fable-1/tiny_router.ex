defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0`
  > and `match/1` in your module.

  Each `get/2` call pairs a path with the module that handles it. A path
  segment that starts with a colon, such as `:id`, matches any single
  segment and is returned in the params under that name.

  ## Examples

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      iex> MyApp.Router.routes()
      [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      iex> MyApp.Router.match("/users/42")
      {:ok, MyApp.UserHandler, %{id: "42"}}

      iex> MyApp.Router.match("/missing")
      :error
  """

  @typedoc "A declared route: the path as written and the module that handles it."
  @type route :: {String.t(), module()}

  @typedoc "The values matched by `:name` segments, keyed by name."
  @type params :: %{optional(atom()) => String.t()}

  @typedoc false
  @type segment :: String.t() | {:param, atom()}

  @typedoc false
  @type compiled_route :: {[segment()], module()}

  defguardp is_module_name(handler) when is_atom(handler) and handler not in [nil, true, false]

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

  `path` must be a string and `handler` a module name; anything else fails
  the compilation of the router module. Routes are matched in the order
  they are declared.

  ## Examples

      get "/", MyApp.PageHandler
      get "/users/:id", MyApp.UserHandler
  """
  defmacro get(path, handler) do
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:match, 1}})

    quote do
      TinyRouter.__route__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  @spec __route__(module(), String.t(), module()) :: :ok
  def __route__(module, path, handler) when is_binary(path) and is_module_name(handler) do
    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  def __route__(_module, path, _handler) when not is_binary(path) do
    raise ArgumentError, "the path of a route must be a string, got: #{inspect(path)}"
  end

  def __route__(_module, path, handler) do
    raise ArgumentError,
          "the handler for #{inspect(path)} must be a module name, got: #{inspect(handler)}"
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    compiled_routes = Enum.map(routes, fn {path, handler} -> {compile_path(path), handler} end)

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
  @spec __match__([compiled_route()], String.t()) :: {:ok, module(), params()} | :error
  def __match__(compiled_routes, path) do
    segments = split_path(path)

    Enum.find_value(compiled_routes, :error, fn {pattern, handler} ->
      case match_segments(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp compile_path(path), do: Enum.map(split_path(path), &compile_segment/1)

  # The name comes from the developer's route declaration, not from a request,
  # so turning it into an atom cannot exhaust the atom table.
  defp compile_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp compile_segment(literal), do: literal

  defp split_path(path), do: String.split(path, "/", trim: true)

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, name} | pattern], [segment | segments], params) do
    match_segments(pattern, segments, Map.put(params, name, segment))
  end

  defp match_segments([segment | pattern], [segment | segments], params) do
    match_segments(pattern, segments, params)
  end

  defp match_segments(_pattern, _segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
