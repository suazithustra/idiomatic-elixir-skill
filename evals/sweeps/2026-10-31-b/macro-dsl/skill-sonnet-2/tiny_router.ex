defmodule TinyRouter do
  @moduledoc """
  A small DSL (domain-specific language) for declaring routes.

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
  `ArgumentError` when the router module compiles. Routes are tried in
  declaration order and the first match wins.
  """

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

  Segments that start with `:`, such as `:id` in `"/users/:id"`, match any
  single segment and are returned in the params map under their name, as a
  string key.
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

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc "Matches a request path against the declared routes."
      @spec match(String.t()) :: {:ok, module(), %{String.t() => String.t()}} | :error
      def match(path), do: TinyRouter.__match__(routes(), path)
    end
  end

  @doc false
  @spec __define__(module(), term(), term()) :: :ok
  def __define__(module, path, handler) when is_binary(path) do
    if not module?(handler) do
      raise ArgumentError,
            "route handler must be a module name such as MyApp.PageHandler, got: #{inspect(handler)}"
    end

    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  def __define__(_module, path, _handler) do
    raise ArgumentError, "route path must be a string, got: #{inspect(path)}"
  end

  @doc false
  @spec __match__([{String.t(), module()}], String.t()) ::
          {:ok, module(), %{String.t() => String.t()}} | :error
  def __match__(routes, path) when is_binary(path) do
    find_route(routes, split(path))
  end

  defp module?(handler) do
    is_atom(handler) and Macro.classify_atom(handler) == :alias
  end

  defp find_route([], _segments), do: :error

  defp find_route([{pattern, handler} | rest], segments) do
    case match_segments(split(pattern), segments, %{}) do
      {:ok, params} ->
        {:ok, handler, params}

      :error ->
        find_route(rest, segments)
    end
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([":" <> name | pattern], [value | segments], params) do
    match_segments(pattern, segments, Map.put(params, name, value))
  end

  defp match_segments([segment | pattern], [segment | segments], params) do
    match_segments(pattern, segments, params)
  end

  defp match_segments(_pattern, _segments, _params), do: :error

  defp split(path), do: String.split(path, "/", trim: true)
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
