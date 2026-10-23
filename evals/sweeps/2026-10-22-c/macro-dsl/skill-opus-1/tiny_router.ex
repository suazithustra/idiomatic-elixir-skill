defmodule TinyRouter do
  @moduledoc """
  A tiny DSL for declaring routes and matching request paths against them.

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

  @typedoc "Path parameters captured from `:name` segments, keyed by name."
  @type params() :: %{String.t() => String.t()}

  @typep segment() :: String.t() | {:param, String.t()}
  @typep compiled_route() :: {[segment()], module()}

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)

      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route from `path` to `handler`.

  `path` must be a string starting with `/`. Segments written as `:name`
  match any single path segment and are returned in the params under `"name"`.
  `handler` must be a module name. Either mistake fails at compile time.
  """
  defmacro get(path, handler) do
    # The handler is only stored, never called at compile time, so expanding
    # it as if inside a function avoids a compile-time dependency on it.
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:match, 1}})

    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(:tiny_router_routes)
      |> Enum.reverse()

    compiled_routes = Enum.map(routes, fn {path, handler} -> {split_path(path), handler} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc "Matches `path` against the declared routes, first match wins."
      @spec match(String.t()) :: {:ok, module(), TinyRouter.params()} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled_routes)), path)
      end
    end
  end

  @doc false
  @spec __define__(module(), term(), term()) :: :ok
  def __define__(module, path, handler) do
    validate_path!(path)
    validate_handler!(handler)
    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  @doc false
  @spec __match__([compiled_route()], String.t()) :: {:ok, module(), params()} | :error
  def __match__(compiled_routes, path) do
    request_segments = String.split(path, "/", trim: true)

    Enum.find_value(compiled_routes, :error, fn {route_segments, handler} ->
      case match_segments(route_segments, request_segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp validate_path!("/" <> _rest), do: :ok

  defp validate_path!(path) when is_binary(path) do
    raise ArgumentError, "TinyRouter route path must start with \"/\", got: #{inspect(path)}"
  end

  defp validate_path!(path) do
    raise ArgumentError, "TinyRouter route path must be a string, got: #{inspect(path)}"
  end

  defp validate_handler!(handler) when is_atom(handler) do
    if not module_name?(handler) do
      raise_invalid_handler!(handler)
    end

    :ok
  end

  defp validate_handler!(handler), do: raise_invalid_handler!(handler)

  defp module_name?(atom), do: match?("Elixir." <> _, Atom.to_string(atom))

  defp raise_invalid_handler!(handler) do
    raise ArgumentError,
          "TinyRouter route handler must be a module name such as MyApp.PageHandler, " <>
            "got: #{inspect(handler)}"
  end

  defp split_path(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&compile_segment/1)
  end

  defp compile_segment(":" <> name), do: {:param, name}
  defp compile_segment(literal), do: literal

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, name} | route_rest], [value | request_rest], params) do
    match_segments(route_rest, request_rest, Map.put(params, name, value))
  end

  defp match_segments([literal | route_rest], [literal | request_rest], params) do
    match_segments(route_rest, request_rest, params)
  end

  defp match_segments(_route_segments, _request_segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
