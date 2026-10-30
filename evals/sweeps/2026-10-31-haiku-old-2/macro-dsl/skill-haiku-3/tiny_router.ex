defmodule TinyRouter do
  @moduledoc """
  Declares path routes in a module and matches request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > Imports `get/2` and sets `@before_compile` so the module gets
  > `routes/0` and `match/1`. Routes are checked when the module compiles.

  ## Path patterns

  A segment that starts with `:` captures that part of the request path.
  `"/users/:id"` matches `"/users/42"` with params `%{id: "42"}`.
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
  Declares a route from `path` to `handler`, in declaration order.
  """
  defmacro get(path, handler) do
    quote do
      TinyRouter.__put_route__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  def __put_route__(module, path, handler) do
    if not is_binary(path) do
      raise ArgumentError, "route path must be a string, got: #{inspect(path)}"
    end

    if not valid_handler?(handler) do
      raise ArgumentError,
            "handler for #{inspect(path)} must be a module name, got: #{inspect(handler)}"
    end

    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  defp valid_handler?(handler), do: is_atom(handler) and handler not in [nil, true, false]

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    compiled = Enum.map(routes, fn {path, handler} -> {parse_path(path), handler} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc "Finds the first route that matches `request_path`."
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(request_path) when is_binary(request_path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled)), request_path)
      end
    end
  end

  @doc false
  def __match__(compiled_routes, request_path) do
    segments = String.split(request_path, "/", trim: true)
    Enum.find_value(compiled_routes, :error, &match_route(&1, segments))
  end

  defp match_route({pattern, handler}, segments) do
    case match_segments(pattern, segments, %{}) do
      {:ok, params} -> {:ok, handler, params}
      :error -> nil
    end
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, name} | pattern], [value | segments], params) do
    match_segments(pattern, segments, Map.put(params, name, value))
  end

  defp match_segments([literal | pattern], [literal | segments], params) do
    match_segments(pattern, segments, params)
  end

  defp match_segments(_pattern, _segments, _params), do: :error

  defp parse_path(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&parse_segment/1)
  end

  defp parse_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp parse_segment(literal), do: literal
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
