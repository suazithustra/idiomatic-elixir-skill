defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

  ## Usage

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.routes()
      #=> [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{id: "42"}}

  Routes are checked when the router module compiles. A path that is not a
  string, or a handler that is not a module name, raises `ArgumentError`.
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  defmacro get(path, handler) do
    # The handler is only stored, never called, so it should not become a
    # compile-time dependency of the router module.
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:routes, 0}})

    quote location: :keep do
      TinyRouter.__put_route__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  @spec __put_route__(module(), term(), term()) :: :ok
  def __put_route__(module, path, handler) do
    validate_path!(path)
    validate_handler!(handler)
    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    patterns = Enum.map(routes, fn {path, handler} -> {parse_route(path), handler} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc "Matches a request path against the declared routes."
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path), do: TinyRouter.__match__(unquote(Macro.escape(patterns)), path)
    end
  end

  @doc false
  @spec __match__([{[String.t() | {:param, atom()}], module()}], String.t()) ::
          {:ok, module(), %{atom() => String.t()}} | :error
  def __match__(patterns, path) when is_binary(path) do
    segments = String.split(path, "/", trim: true)

    Enum.find_value(patterns, :error, fn {pattern, handler} ->
      case match_segments(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp validate_path!(path) when is_binary(path), do: :ok

  defp validate_path!(path) do
    raise ArgumentError, "route path must be a string, got: #{inspect(path)}"
  end

  defp validate_handler!(handler) when is_atom(handler) and handler not in [nil, true, false],
    do: :ok

  defp validate_handler!(handler) do
    raise ArgumentError, "route handler must be a module name, got: #{inspect(handler)}"
  end

  defp parse_route(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&parse_segment/1)
  end

  defp parse_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp parse_segment(literal), do: literal

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, name} | pattern], [segment | segments], params) do
    match_segments(pattern, segments, Map.put(params, name, segment))
  end

  defp match_segments([literal | pattern], [literal | segments], params) do
    match_segments(pattern, segments, params)
  end

  defp match_segments(_pattern, _segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
