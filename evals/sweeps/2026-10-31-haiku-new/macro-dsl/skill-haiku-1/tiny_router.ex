defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

  Add `use TinyRouter` to a module, then declare each route with `get/2`:

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

  A path segment that starts with `:` captures the value at that position.
  `match/1` returns the first route that matches, in declaration order.
  """

  @doc """
  Declares a route. `path` must be a string literal and `handler` a module name.

  Both are checked when the module compiles, so a mistake fails the build
  at the `get` line.
  """
  defmacro get(path, handler) do
    path = Macro.expand(path, __CALLER__)
    handler = Macro.expand(handler, __CALLER__)

    if not is_binary(path) do
      compile_error!(__CALLER__, "route path must be a string, got: #{Macro.to_string(path)}")
    end

    if not module_name?(handler) do
      message = "route handler must be a module name, got: #{Macro.to_string(handler)}"
      compile_error!(__CALLER__, message)
    end

    quote do
      @tiny_router_routes {unquote(path), unquote(handler)}
    end
  end

  @doc false
  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    # Accumulated attributes are returned newest first.
    routes =
      env.module
      |> Module.get_attribute(:tiny_router_routes)
      |> Enum.reverse()

    compiled = Enum.map(routes, fn {path, handler} -> {compile_path(path), handler} end)

    quote do
      @doc """
      Returns the declared `{path, handler}` pairs in declaration order.
      """
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc """
      Returns `{:ok, handler, params}` for the first route that matches `path`,
      or `:error`.
      """
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
      end
    end
  end

  @doc false
  @spec __match__([{[{:static, String.t()} | {:param, atom()}], module()}], String.t()) ::
          {:ok, module(), %{atom() => String.t()}} | :error
  def __match__(routes, path) do
    segments = split_path(path)

    Enum.find_value(routes, :error, fn {pattern, handler} ->
      case match_segments(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp module_name?(value), do: is_atom(value) and value not in [nil, true, false]

  defp compile_error!(env, description) do
    raise CompileError, description: description, file: env.file, line: env.line
  end

  defp compile_path(path), do: Enum.map(split_path(path), &compile_segment/1)

  defp compile_segment(":" <> name) when name != "", do: {:param, String.to_atom(name)}
  defp compile_segment(segment), do: {:static, segment}

  defp split_path(path), do: String.split(path, "/", trim: true)

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:static, text} | pattern], [text | segments], params) do
    match_segments(pattern, segments, params)
  end

  defp match_segments([{:param, name} | pattern], [value | segments], params) do
    match_segments(pattern, segments, Map.put(params, name, value))
  end

  defp match_segments(_pattern, _segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
