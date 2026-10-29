defmodule TinyRouter do
  @moduledoc """
  Declares a list of paths and the handler module for each one.

  A module that calls `use TinyRouter` gets `get/2`, which records one route,
  and two functions built from the recorded routes:

    * `routes/0` returns `{path, handler}` pairs in declaration order.
    * `match/1` takes a request path and returns `{:ok, handler, params}` for
      the first matching route, or `:error`.

  A path segment that starts with `:` is a parameter, so `"/users/:id"`
  matches `"/users/42"` with `%{"id" => "42"}`. Paths and handlers are checked
  when the router module compiles.
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route from `path` to the handler module `handler`.
  """
  defmacro get(path, handler) do
    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler), __ENV__)
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    compiled = Enum.map(routes, fn {path, handler} -> {handler, compile_path(path)} end)

    quote do
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @spec match(String.t()) :: {:ok, module(), %{String.t() => String.t()}} | :error
      def match(path), do: TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
    end
  end

  @doc false
  @spec __define__(module(), term(), term(), Macro.Env.t()) :: :ok
  def __define__(module, path, handler, env) do
    validate_path!(path, env)
    validate_handler!(handler, env)
    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  @doc false
  @spec __match__([{module(), [{:static | :param, String.t()}]}], String.t()) ::
          {:ok, module(), %{String.t() => String.t()}} | :error
  def __match__(compiled, path) do
    segments = String.split(path, "/", trim: true)
    Enum.find_value(compiled, :error, &match_route(&1, segments))
  end

  defp validate_path!(path, _env) when is_binary(path), do: :ok

  defp validate_path!(path, env) do
    compile_error!(env, "route path must be a string, got: #{inspect(path)}")
  end

  defp validate_handler!(handler, _env)
       when is_atom(handler) and handler not in [nil, true, false] do
    :ok
  end

  defp validate_handler!(handler, env) do
    compile_error!(env, "handler must be a module name, got: #{inspect(handler)}")
  end

  defp compile_error!(env, description) do
    raise CompileError, file: env.file, line: env.line, description: description
  end

  defp compile_path(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&compile_segment/1)
  end

  defp compile_segment(":" <> name), do: {:param, name}
  defp compile_segment(segment), do: {:static, segment}

  defp match_route({handler, pattern}, segments) do
    case match_segments(pattern, segments, %{}) do
      {:ok, params} -> {:ok, handler, params}
      :error -> nil
    end
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:static, segment} | pattern], [segment | segments], params) do
    match_segments(pattern, segments, params)
  end

  defp match_segments([{:param, name} | pattern], [value | segments], params) do
    match_segments(pattern, segments, Map.put(params, name, value))
  end

  defp match_segments(_pattern, _segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
