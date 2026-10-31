defmodule TinyRouter do
  @moduledoc """
  A small path router declared with a `get/2` macro.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` into your module and, once
  > the module is compiled, defines `routes/0` and `match/1` in it.

  ## Examples

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      iex> MyApp.Router.routes()
      [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]
      iex> MyApp.Router.match("/users/42")
      {:ok, MyApp.UserHandler, %{id: "42"}}
      iex> MyApp.Router.match("/missing")
      :error

  A path segment that starts with `:` matches any one request segment and binds
  it under that name in the params map. Routes are tried in declaration order
  and the first match wins. Empty segments are ignored, so `"/users/42/"`
  matches `"/users/:id"`. A path that is not a string, or a handler that is not
  a module name, raises `ArgumentError` while the router module compiles.
  """

  @typedoc "Parameters bound from `:name` segments of the matched route."
  @type params :: %{optional(atom()) => String.t()}

  @typep segment :: String.t() | {:param, atom()}
  @typep route :: {String.t(), [segment()], module()}

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route for `path`, handled by `handler`.

  `path` must be a string and `handler` a module name; anything else raises
  `ArgumentError` when the router module compiles. The handler is only stored,
  so declaring a route does not make the router depend on it at compile time.
  """
  defmacro get(path, handler) do
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:match, 1}})

    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    pairs = Macro.escape(Enum.map(routes, fn {path, _segments, handler} -> {path, handler} end))
    compiled_routes = Macro.escape(routes)

    quote do
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(pairs)

      @spec match(String.t()) :: {:ok, module(), TinyRouter.params()} | :error
      def match(request_path) when is_binary(request_path) do
        TinyRouter.__match__(unquote(compiled_routes), request_path)
      end
    end
  end

  @doc false
  @spec __define__(module(), term(), term()) :: :ok
  def __define__(module, path, handler)
      when is_binary(path) and is_atom(handler) and handler not in [nil, true, false] do
    Module.put_attribute(module, :tiny_router_routes, {path, compile_path(path), handler})
  end

  def __define__(_module, path, _handler) when not is_binary(path) do
    raise ArgumentError, "get/2 expects the path to be a string, got: #{inspect(path)}"
  end

  def __define__(_module, _path, handler) do
    raise ArgumentError, "get/2 expects the handler to be a module name, got: #{inspect(handler)}"
  end

  @doc false
  @spec __match__([route()], String.t()) :: {:ok, module(), params()} | :error
  def __match__(routes, request_path) do
    segments = split_path(request_path)
    Enum.find_value(routes, :error, &match_route(&1, segments))
  end

  defp match_route({_path, pattern, handler}, segments) do
    case bind_params(pattern, segments, %{}) do
      {:ok, params} -> {:ok, handler, params}
      :error -> nil
    end
  end

  defp bind_params([], [], params), do: {:ok, params}

  defp bind_params([{:param, name} | pattern], [segment | segments], params) do
    bind_params(pattern, segments, Map.put(params, name, segment))
  end

  defp bind_params([segment | pattern], [segment | segments], params) do
    bind_params(pattern, segments, params)
  end

  defp bind_params(_pattern, _segments, _params), do: :error

  defp compile_path(path), do: path |> split_path() |> Enum.map(&compile_segment/1)

  # Route paths are literals in the router's source, so the atoms created here
  # are bounded by the code, not by request input.
  defp compile_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp compile_segment(segment), do: segment

  defp split_path(path), do: String.split(path, "/", trim: true)
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
