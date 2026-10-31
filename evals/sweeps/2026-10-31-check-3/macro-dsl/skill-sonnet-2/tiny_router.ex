defmodule TinyRouter do
  @moduledoc """
  A small DSL (domain-specific language) for declaring routes.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0`
  > and `match/1` in your module.

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

      MyApp.Router.match("/missing")
      #=> :error
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

  `path` must be a string, where a segment starting with `:` captures the
  request segment in that position. `handler` must be a module name. Anything
  else raises `ArgumentError` when the calling module compiles.
  """
  defmacro get(path, handler) do
    # Expanding as if inside a function keeps the handler a runtime dependency,
    # so recompiling a handler does not recompile the router.
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:routes, 0}})

    path = validate_path!(path)
    handler = validate_handler!(handler)

    quote do
      @tiny_router_routes {unquote(path), unquote(handler)}
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

      @doc """
      Matches a request path against the declared routes.

      Returns `{:ok, handler, params}`, where `params` maps each `:name` segment
      to the request segment, or `:error` when no route matches.
      """
      @spec match(String.t()) :: {:ok, module(), %{String.t() => String.t()}} | :error
      def match(path) when is_binary(path), do: TinyRouter.match(routes(), path)
    end
  end

  @doc false
  @spec match([{String.t(), module()}], String.t()) ::
          {:ok, module(), %{String.t() => String.t()}} | :error
  def match(routes, path) when is_binary(path) do
    segments = split(path)

    Enum.find_value(routes, :error, fn {pattern, handler} ->
      case match_segments(split(pattern), segments, %{}) do
        {:ok, params} ->
          {:ok, handler, params}

        :error ->
          nil
      end
    end)
  end

  defp split(path), do: String.split(path, "/", trim: true)

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([":" <> name | pattern], [value | segments], params) do
    match_segments(pattern, segments, Map.put(params, name, value))
  end

  defp match_segments([segment | pattern], [segment | segments], params) do
    match_segments(pattern, segments, params)
  end

  defp match_segments(_pattern, _segments, _params), do: :error

  defp validate_path!(path) when is_binary(path), do: path

  defp validate_path!(path) do
    raise ArgumentError,
          "TinyRouter route path must be a string, got: #{Macro.to_string(path)}"
  end

  defp validate_handler!(handler) when is_atom(handler) and handler not in [nil, true, false] do
    handler
  end

  defp validate_handler!(handler) do
    raise ArgumentError,
          "TinyRouter route handler must be a module name, got: #{Macro.to_string(handler)}"
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
