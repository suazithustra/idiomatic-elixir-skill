defmodule TinyRouter do
  @moduledoc """
  A tiny routing DSL that maps request paths to handler modules.

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

      MyApp.Router.match("/missing")
      #=> :error

  A path segment starting with `:` captures the matching request segment
  under that name, as a string key in the params map.
  """

  @typedoc "A compiled path segment: a literal to match exactly or a named capture."
  @type segment :: {:literal, String.t()} | {:param, String.t()}

  @typedoc "Captured path parameters, keyed by the name after `:`."
  @type params :: %{String.t() => String.t()}

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route that sends requests for `path` to `handler`.

  `path` must be a string and `handler` a module name, or compiling the
  router fails with an `ArgumentError`.
  """
  defmacro get(path, handler) do
    # The handler is only called at runtime, so expanding it in a function
    # context avoids a compile-time dependency on the handler module.
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:match, 1}})

    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  @spec __define__(module(), String.t(), module()) :: :ok
  def __define__(router, path, handler) do
    if not is_binary(path) do
      raise ArgumentError,
            "route path in #{inspect(router)} must be a string, got: #{inspect(path)}"
    end

    if not module_name?(handler) do
      raise ArgumentError,
            "handler for route #{inspect(path)} in #{inspect(router)} must be a module name " <>
              "such as MyApp.PageHandler, got: #{inspect(handler)}"
    end

    Module.put_attribute(router, :tiny_router_routes, {path, handler})
  end

  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    compiled = Enum.map(routes, fn {path, handler} -> {compile_path(path), handler} end)

    quote do
      @doc "Returns the declared `{path, handler}` routes in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc "Finds the first route matching `path`."
      @spec match(String.t()) :: {:ok, module(), TinyRouter.params()} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
      end
    end
  end

  @doc false
  @spec __match__([{[segment()], module()}], String.t()) ::
          {:ok, module(), params()} | :error
  def __match__(compiled_routes, path) do
    request_segments = split_path(path)

    Enum.find_value(compiled_routes, :error, fn {route_segments, handler} ->
      case match_segments(route_segments, request_segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp module_name?(handler) when is_atom(handler) do
    String.starts_with?(Atom.to_string(handler), "Elixir.")
  end

  defp module_name?(_handler), do: false

  defp compile_path(path), do: Enum.map(split_path(path), &compile_segment/1)

  defp compile_segment(":" <> name), do: {:param, name}
  defp compile_segment(literal), do: {:literal, literal}

  defp split_path(path), do: String.split(path, "/", trim: true)

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:literal, literal} | route_rest], [literal | request_rest], params) do
    match_segments(route_rest, request_rest, params)
  end

  defp match_segments([{:param, name} | route_rest], [value | request_rest], params) do
    match_segments(route_rest, request_rest, Map.put(params, name, value))
  end

  defp match_segments(_route_segments, _request_segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
