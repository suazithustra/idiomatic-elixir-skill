defmodule TinyRouter do
  @moduledoc """
  Declares path routes in a module and matches request paths against them.

  ## Example

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{id: "42"}}

  The path must be a string literal and the handler must be a module name.
  Any other value fails when the module compiles.
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
  Declares a route from `path` (a string literal) to `handler` (a module name).
  """
  defmacro get(path, handler) do
    route = route!(path, handler, __CALLER__)

    quote do
      @tiny_router_routes unquote(Macro.escape(route))
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(:tiny_router_routes)
      |> Enum.reverse()

    compiled = Enum.map(routes, fn {path, handler} -> {compile_path(path), handler} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc "Returns the handler for `path` and the values of its `:name` segments."
      @spec match(String.t()) :: {:ok, module(), map()} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
      end
    end
  end

  @doc false
  @spec __match__([{[String.t() | {:param, atom()}], module()}], String.t()) ::
          {:ok, module(), map()} | :error
  def __match__(routes, path) do
    segments = String.split(path, "/", trim: true)
    Enum.find_value(routes, :error, &match_route(&1, segments))
  end

  defp route!(path, _handler, caller) when not is_binary(path) do
    raise_at!(caller, "route path must be a string literal, got: #{Macro.to_string(path)}")
  end

  defp route!(path, handler, caller) do
    case Macro.expand(handler, caller) do
      module when is_atom(module) and module not in [nil, true, false] ->
        {path, module}

      _other ->
        raise_at!(caller, "route handler must be a module name, got: #{Macro.to_string(handler)}")
    end
  end

  defp raise_at!(caller, description) do
    raise CompileError, description: description, file: caller.file, line: caller.line
  end

  defp compile_path(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&compile_segment/1)
  end

  defp compile_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp compile_segment(literal), do: literal

  defp match_route({pattern, handler}, segments) do
    case match_segments(pattern, segments, %{}) do
      {:ok, params} -> {:ok, handler, params}
      :error -> nil
    end
  end

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

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
