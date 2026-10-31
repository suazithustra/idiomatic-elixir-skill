defmodule TinyRouter do
  @moduledoc """
  A small DSL (domain-specific language) for declaring routes and matching request paths.

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

  A path or handler of the wrong type raises `ArgumentError` while the router
  module compiles.
  """

  @type params :: %{optional(String.t()) => String.t()}

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)

      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route for `path`, served by `handler`.

  Segments starting with `:` match any non-empty segment and are returned in
  the params map under their name, without the colon.
  """
  defmacro get(path, handler) do
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:call, 2}})

    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

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
      Finds the first declared route that matches `request_path`.

      Returns `{:ok, handler, params}`, or `:error` when no route matches.
      """
      @spec match(String.t()) :: {:ok, module(), TinyRouter.params()} | :error
      def match(request_path) when is_binary(request_path) do
        TinyRouter.match(routes(), request_path)
      end
    end
  end

  @doc false
  @spec __define__(module(), String.t(), module()) :: :ok
  def __define__(router, path, handler) when is_binary(path) do
    if not module_name?(handler) do
      raise ArgumentError,
            "#{inspect(router)}: the handler for #{inspect(path)} must be a module name " <>
              "such as MyApp.PageHandler, got: #{inspect(handler)}"
    end

    Module.put_attribute(router, :tiny_router_routes, {path, handler})
  end

  def __define__(router, path, _handler) do
    raise ArgumentError,
          "#{inspect(router)}: a route path must be a string such as \"/users/:id\", " <>
            "got: #{inspect(path)}"
  end

  @doc false
  @spec match([{String.t(), module()}], String.t()) :: {:ok, module(), params()} | :error
  def match(routes, request_path) do
    find_route(routes, split(request_path))
  end

  defp module_name?(handler) do
    is_atom(handler) and Macro.classify_atom(handler) == :alias
  end

  defp find_route([], _request_segments), do: :error

  defp find_route([{path, handler} | rest], request_segments) do
    case match_segments(split(path), request_segments, %{}) do
      {:ok, params} ->
        {:ok, handler, params}

      :error ->
        find_route(rest, request_segments)
    end
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([":" <> name | route_rest], [value | request_rest], params) do
    match_segments(route_rest, request_rest, Map.put(params, name, value))
  end

  defp match_segments([segment | route_rest], [segment | request_rest], params) do
    match_segments(route_rest, request_rest, params)
  end

  defp match_segments(_route_segments, _request_segments, _params), do: :error

  defp split(path), do: String.split(path, "/", trim: true)
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
