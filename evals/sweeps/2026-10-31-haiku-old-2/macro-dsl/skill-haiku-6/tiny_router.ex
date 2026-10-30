defmodule TinyRouter do
  @moduledoc """
  Declares path routes in a module and matches request paths to handlers.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2`, creates a route list on
  > your module, and defines `routes/0` and `match/1` at the end of the module.

  ## Example

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{id: "42"}}

  Segments that start with `:` capture a value into `params`. The first
  route in declaration order that matches wins.
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

  `path` must be a string and `handler` must be a module name. Both are
  checked when the module compiles.
  """
  defmacro get(path, handler) do
    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    public_routes = Enum.map(routes, fn {path, handler, _segments} -> {path, handler} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(public_routes))

      @doc "Returns `{:ok, handler, params}` for the first route matching `path`, or `:error`."
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(routes)), path)
      end
    end
  end

  @doc false
  @spec __define__(module(), term(), term()) :: :ok
  def __define__(module, path, handler) do
    check_path!(module, path)
    check_handler!(module, handler)
    Module.put_attribute(module, :tiny_router_routes, {path, handler, parse_path(path)})
  end

  @doc false
  @spec __match__([{String.t(), module(), list()}], String.t()) ::
          {:ok, module(), %{atom() => String.t()}} | :error
  def __match__(routes, path) do
    request = String.split(path, "/", trim: true)

    Enum.find_value(routes, :error, fn {_path, handler, pattern} ->
      case match_segments(pattern, request, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp check_path!(_module, path) when is_binary(path), do: :ok

  defp check_path!(module, path) do
    raise ArgumentError,
          "route path must be a string, got: #{inspect(path)} (in #{inspect(module)})"
  end

  defp check_handler!(_module, handler)
       when is_atom(handler) and handler not in [nil, true, false],
       do: :ok

  defp check_handler!(module, handler) do
    raise ArgumentError,
          "route handler must be a module name, got: #{inspect(handler)} " <>
            "(in #{inspect(module)})"
  end

  defp parse_path(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&parse_segment/1)
  end

  defp parse_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp parse_segment(segment), do: segment

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, name} | pattern], [value | request], params) do
    match_segments(pattern, request, Map.put(params, name, value))
  end

  defp match_segments([segment | pattern], [segment | request], params) do
    match_segments(pattern, request, params)
  end

  defp match_segments(_pattern, _request, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
