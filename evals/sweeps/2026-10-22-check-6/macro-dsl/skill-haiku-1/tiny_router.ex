defmodule TinyRouter do
  @moduledoc """
  Declares a route table in a module and matches request paths against it.

  `use TinyRouter` imports `get/2` and defines `routes/0` and `match/1` in the
  calling module. Routes are checked when the module compiles, so a path that
  is not a string, or a handler that is not a module name, stops the build with
  an `ArgumentError`.

  ## Example

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{id: "42"}}
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route from `path` to `handler`. Call it only in a module that
  calls `use TinyRouter`.
  """
  defmacro get(path, handler) do
    quote do
      TinyRouter.__put_route__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc "Returns the handler for `path` and its `:name` params, or `:error`."
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path) when is_binary(path), do: TinyRouter.__match__(routes(), path)
    end
  end

  @doc false
  @spec __put_route__(module(), term(), term()) :: :ok
  def __put_route__(module, path, handler) do
    validate_path!(path)
    validate_handler!(handler)
    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  @doc false
  @spec __match__([{String.t(), module()}], String.t()) ::
          {:ok, module(), %{atom() => String.t()}} | :error
  def __match__(routes, path) do
    segments = split_path(path)
    Enum.find_value(routes, :error, &match_route(&1, segments))
  end

  defp validate_path!(path) when is_binary(path), do: :ok

  defp validate_path!(path) do
    message = "route path must be a string such as \"/users/:id\", got: #{inspect(path)}"
    raise ArgumentError, message
  end

  defp validate_handler!(handler) when is_atom(handler) and handler not in [nil, true, false],
    do: :ok

  defp validate_handler!(handler) do
    message =
      "route handler must be a module name such as MyApp.PageHandler, got: #{inspect(handler)}"

    raise ArgumentError, message
  end

  defp match_route({route_path, handler}, segments) do
    case match_segments(split_path(route_path), segments, %{}) do
      {:ok, params} -> {:ok, handler, params}
      :error -> nil
    end
  end

  defp match_segments([], [], params), do: {:ok, params}

  # Parameter names come from the declared routes, not from requests, so the
  # set of atoms created here is bounded by the source code.
  defp match_segments([":" <> name | pattern], [segment | segments], params) do
    match_segments(pattern, segments, Map.put(params, String.to_atom(name), segment))
  end

  defp match_segments([segment | pattern], [segment | segments], params) do
    match_segments(pattern, segments, params)
  end

  defp match_segments(_pattern, _segments, _params), do: :error

  defp split_path(path), do: String.split(path, "/", trim: true)
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
