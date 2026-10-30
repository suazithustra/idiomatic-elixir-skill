defmodule TinyRouter do
  @moduledoc """
  A small DSL (domain-specific language) for declaring routes.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports the `get/2` macro and defines
  > `routes/0` and `match/1` in your module.

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.routes()
      #=> [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{id: "42"}}

  A path that is not a string, or a handler that is not a module name, raises
  `ArgumentError` when the router module compiles.
  """

  @typedoc "One path segment: literal text, or a `:name` parameter."
  @type segment :: String.t() | {:param, atom()}

  @doc false
  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)

      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route for `path`, served by `handler`.

  Segments starting with `:` capture the request segment in the params map.
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

    declared = Enum.map(routes, fn {path, handler, _segments} -> {path, handler} end)
    compiled = Enum.map(routes, fn {_path, handler, segments} -> {handler, segments} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(declared))

      @doc """
      Finds the handler for a request path.

      Returns `{:ok, handler, params}`, or `:error` when no route matches.
      """
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(request_path) when is_binary(request_path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled)), request_path)
      end
    end
  end

  @doc false
  @spec __define__(module(), term(), term()) :: :ok
  def __define__(module, path, handler) when is_binary(path) and is_atom(handler) do
    if handler in [nil, true, false] do
      raise ArgumentError, "route handler must be a module name, got: #{inspect(handler)}"
    end

    segments = parse_path!(path)
    Module.put_attribute(module, :tiny_router_routes, {path, handler, segments})
  end

  def __define__(_module, path, _handler) when not is_binary(path) do
    raise ArgumentError, "route path must be a string, got: #{inspect(path)}"
  end

  def __define__(_module, _path, handler) do
    raise ArgumentError, "route handler must be a module name, got: #{inspect(handler)}"
  end

  @doc false
  @spec __match__([{module(), [segment()]}], String.t()) ::
          {:ok, module(), %{atom() => String.t()}} | :error
  def __match__(routes, request_path) do
    find_route(routes, split(request_path))
  end

  defp parse_path!("/" <> _ = path) do
    path
    |> split()
    |> Enum.map(&parse_segment!(&1, path))
  end

  defp parse_path!(path) do
    raise ArgumentError, ~s(route path must start with "/", got: #{inspect(path)})
  end

  defp parse_segment!(":", path) do
    raise ArgumentError, "route path has a parameter without a name: #{inspect(path)}"
  end

  # The names come from the router's own source code, not from request data,
  # so the atoms are bounded by what the developer writes.
  defp parse_segment!(":" <> name, _path), do: {:param, String.to_atom(name)}
  defp parse_segment!(literal, _path), do: literal

  defp split(path), do: String.split(path, "/", trim: true)

  defp find_route([], _segments), do: :error

  defp find_route([{handler, pattern} | rest], segments) do
    case match_segments(pattern, segments, %{}) do
      {:ok, params} ->
        {:ok, handler, params}

      :error ->
        find_route(rest, segments)
    end
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, name} | pattern], [value | segments], params) do
    match_segments(pattern, segments, Map.put(params, name, value))
  end

  defp match_segments([literal | pattern], [literal | segments], params) do
    match_segments(pattern, segments, params)
  end

  defp match_segments(_pattern, _segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
