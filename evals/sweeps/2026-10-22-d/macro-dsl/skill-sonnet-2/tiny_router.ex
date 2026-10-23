defmodule TinyRouter do
  @moduledoc """
  A tiny compile-time router DSL.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0` and
  > `match/1` in your module.

  ## Examples

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

  @typedoc "A route path segment: a literal string or a `:name` parameter."
  @type segment :: String.t() | {:param, atom()}

  @typedoc "A route as stored by the router: its path, handler and parsed segments."
  @type route :: {String.t(), module(), [segment()]}

  @doc false
  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)

      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route for `path`, handled by the module `handler`.
  """
  defmacro get(path, handler) do
    # The handler is only stored, never called at compile time, so expanding
    # it as if inside a function avoids a compile-time dependency on it.
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

    pairs = Enum.map(routes, fn {path, handler, _segments} -> {path, handler} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(pairs))

      @doc """
      Matches a request path against the declared routes.

      Returns `{:ok, handler, params}` for the first matching route, or `:error`.
      """
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path) when is_binary(path) do
        TinyRouter.match(unquote(Macro.escape(routes)), path)
      end
    end
  end

  @doc false
  @spec __define__(module(), term(), term()) :: :ok
  def __define__(module, path, handler) do
    if not is_binary(path) do
      raise ArgumentError, "route path must be a string, got: #{inspect(path)}"
    end

    if not module_name?(handler) do
      raise ArgumentError, "route handler must be a module name, got: #{inspect(handler)}"
    end

    Module.put_attribute(module, :tiny_router_routes, {path, handler, parse(path)})
  end

  @doc false
  @spec match([route()], String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
  def match(routes, path) do
    request_segments = split(path)

    Enum.find_value(routes, :error, fn {_path, handler, segments} ->
      case match_segments(segments, request_segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp module_name?(handler), do: is_atom(handler) and handler not in [nil, true, false]

  defp parse(path) do
    path
    |> split()
    |> Enum.map(&parse_segment/1)
  end

  # Route paths are written by the library user in source, so the atoms are bounded.
  defp parse_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp parse_segment(literal), do: literal

  defp split(path), do: String.split(path, "/", trim: true)

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, name} | routes], [value | requests], params) do
    match_segments(routes, requests, Map.put(params, name, value))
  end

  defp match_segments([literal | routes], [literal | requests], params) when is_binary(literal) do
    match_segments(routes, requests, params)
  end

  defp match_segments(_routes, _requests, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
