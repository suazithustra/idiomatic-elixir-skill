defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > Imports `get/2` and, when the module compiles, defines `routes/0` and
  > `match/1` in the caller. Nothing else is added to the caller's API.

  Segments that start with `:` are parameters. `"/users/:id"` matches
  `"/users/42"` with params `%{id: "42"}`. Routes are tried in declaration
  order, and the first match wins.
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route from `path` to `handler`.

  Raises a `CompileError` at the call site if `path` is not a string literal,
  if `handler` is not a module name, or if a parameter segment has no name.
  """
  defmacro get(path, handler) do
    path = Macro.expand_literals(path, __CALLER__)
    handler = Macro.expand_literals(handler, __CALLER__)
    validate_route!(path, handler, __CALLER__)

    quote do
      TinyRouter.__put_route__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  @spec __put_route__(module(), String.t(), module()) :: :ok
  def __put_route__(module, path, handler) do
    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    compiled = Enum.map(routes, fn {path, handler} -> {compile_path(path), handler} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc """
      Matches a request path against the declared routes.

      Returns `{:ok, handler, params}` for the first matching route, or `:error`.
      """
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(path, unquote(Macro.escape(compiled)))
      end
    end
  end

  @doc false
  def __match__(path, routes) do
    segments = split(path)

    Enum.find_value(routes, :error, fn {pattern, handler} ->
      case match_segments(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp validate_route!(path, handler, caller) do
    if not is_binary(path) do
      raise_at(caller, "route path must be a string, got: #{Macro.to_string(path)}")
    end

    if not module_name?(handler) do
      raise_at(caller, "route handler must be a module name, got: #{Macro.to_string(handler)}")
    end

    if ":" in split(path) do
      raise_at(caller, "route path #{inspect(path)} has a parameter segment with no name")
    end
  end

  defp raise_at(caller, description) do
    raise CompileError, file: caller.file, line: caller.line, description: description
  end

  defp module_name?(value), do: is_atom(value) and value not in [nil, true, false]

  defp compile_path(path) do
    path
    |> split()
    |> Enum.map(&compile_segment/1)
  end

  defp compile_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp compile_segment(literal), do: literal

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, name} | pattern], [value | segments], params),
    do: match_segments(pattern, segments, Map.put(params, name, value))

  defp match_segments([literal | pattern], [literal | segments], params),
    do: match_segments(pattern, segments, params)

  defp match_segments(_pattern, _segments, _params), do: :error

  defp split(path), do: String.split(path, "/", trim: true)
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
