defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2`, registers the `:tiny_routes`
  > attribute, and adds `@before_compile TinyRouter`. The last one defines
  > `routes/0` and `match/1` in your module.

  ## Paths

  A path is a list of segments separated by `/`. A segment that starts with
  `:` captures the request segment under that name, as a string. Empty
  segments are ignored, so `/users/1/` and `users/1` are the same route.

      get "/users/:id", MyApp.UserHandler
  """

  @doc """
  Declares a route.

  `path` must be a string and `handler` a module name. Anything else raises
  `CompileError` when the module that calls `get/2` is compiled.
  """
  defmacro get(path, handler) do
    location = [file: __CALLER__.file, line: __CALLER__.line]

    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler), unquote(location))
    end
  end

  @doc false
  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_routes) |> Enum.reverse()
    public_routes = Enum.map(routes, fn {path, handler, _segments} -> {path, handler} end)
    compiled = Enum.map(routes, fn {_path, handler, segments} -> {segments, handler} end)

    quote do
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(public_routes))

      @spec match(String.t()) :: {:ok, module(), map()} | :error
      def match(path), do: TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
    end
  end

  @doc false
  @spec __define__(module(), term(), term(), keyword()) :: :ok
  def __define__(module, path, handler, location) do
    check_path(path, location)
    check_handler(handler, location)

    Module.put_attribute(module, :tiny_routes, {path, handler, parse_segments(path)})
  end

  @doc false
  @spec __match__(list(), String.t()) :: {:ok, module(), map()} | :error
  def __match__(routes, path) do
    request_segments = String.split(path, "/", trim: true)

    Enum.find_value(routes, :error, fn {route_segments, handler} ->
      case match_segments(route_segments, request_segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp check_path(path, _location) when is_binary(path), do: :ok

  defp check_path(path, location) do
    raise_compile_error(location, "route path must be a string, got: #{inspect(path)}")
  end

  defp check_handler(handler, _location)
       when is_atom(handler) and handler not in [nil, true, false] do
    :ok
  end

  defp check_handler(handler, location) do
    raise_compile_error(location, "route handler must be a module name, got: #{inspect(handler)}")
  end

  defp parse_segments(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&parse_segment/1)
  end

  defp parse_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp parse_segment(segment), do: {:literal, segment}

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:literal, segment} | routes], [segment | paths], params) do
    match_segments(routes, paths, params)
  end

  defp match_segments([{:param, name} | routes], [value | paths], params) do
    match_segments(routes, paths, Map.put(params, name, value))
  end

  defp match_segments(_routes, _paths, _params), do: :error

  defp raise_compile_error(location, description) do
    error = [file: location[:file], line: location[:line], description: description]
    raise CompileError, error
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
