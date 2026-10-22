defmodule TinyRouter do
  @moduledoc """
  A tiny compile-time router DSL.

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

      MyApp.Router.match("/nope")
      #=> :error

  Param names are returned as string keys, so no atoms are created from
  request paths.
  """

  @typedoc "A route path such as `\"/users/:id\"`."
  @type path :: String.t()

  @typedoc "A parsed route: its path, handler and path segments."
  @type route :: {path(), module(), [String.t() | {:param, String.t()}]}

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

  Raises `ArgumentError` at compile time if `path` is not a string or
  `handler` is not a module name.
  """
  defmacro get(path, handler) do
    # The handler is only stored, never called here, so expanding it as if it
    # were used inside a function avoids a compile-time dependency on it.
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

    declared = for {path, handler, _segments} <- routes, do: {path, handler}
    escaped_routes = Macro.escape(routes)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{TinyRouter.path(), module()}]
      def routes, do: unquote(declared)

      @doc "Matches a request path against the declared routes."
      @spec match(String.t()) :: {:ok, module(), %{optional(String.t()) => String.t()}} | :error
      def match(request_path) when is_binary(request_path) do
        TinyRouter.match(unquote(escaped_routes), request_path)
      end
    end
  end

  @doc false
  @spec __define__(module(), term(), term()) :: :ok
  def __define__(module, path, handler) when is_binary(path) and is_atom(handler) do
    if handler in [nil, true, false] do
      raise ArgumentError,
            "TinyRouter handler must be a module name, got: #{inspect(handler)}"
    end

    Module.put_attribute(module, :tiny_router_routes, {path, handler, parse_path(path)})
  end

  def __define__(_module, path, _handler) when not is_binary(path) do
    raise ArgumentError, "TinyRouter path must be a string, got: #{inspect(path)}"
  end

  def __define__(_module, _path, handler) do
    raise ArgumentError, "TinyRouter handler must be a module name, got: #{inspect(handler)}"
  end

  @doc false
  @spec match([route()], String.t()) :: {:ok, module(), map()} | :error
  def match(routes, request_path) do
    segments = split(request_path)

    Enum.find_value(routes, :error, fn {_path, handler, pattern} ->
      case match_segments(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, name} | pattern], [value | rest], params) do
    match_segments(pattern, rest, Map.put(params, name, value))
  end

  defp match_segments([segment | pattern], [segment | rest], params) when is_binary(segment) do
    match_segments(pattern, rest, params)
  end

  defp match_segments(_pattern, _segments, _params), do: :error

  defp parse_path(path) do
    for segment <- split(path) do
      case segment do
        ":" <> name -> {:param, name}
        literal -> literal
      end
    end
  end

  defp split(path), do: String.split(path, "/", trim: true)
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
