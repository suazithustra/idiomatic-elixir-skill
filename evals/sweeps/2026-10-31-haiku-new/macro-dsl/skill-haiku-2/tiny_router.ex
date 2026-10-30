defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

  Add `use TinyRouter` to a module, then declare routes with `get/2`:

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

  The module gets `routes/0`, which returns the `{path, handler}` pairs in
  declaration order, and `match/1`, which returns `{:ok, handler, params}` for
  the first route that fits the path, or `:error`. Segments written as `:name`
  capture the matching request segment into `params` under the string key
  `"name"`.

  A path must be a string literal and a handler must be a module name. Anything
  else fails when the router module compiles.
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
  Declares a route for `path` that dispatches to `handler`.
  """
  defmacro get(path, handler) do
    path = expand_path!(path, __CALLER__)
    handler = expand_handler!(handler, __CALLER__)

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
  @spec __match__([{[String.t() | {:param, String.t()}], module()}], String.t()) ::
          {:ok, module(), %{String.t() => String.t()}} | :error
  def __match__(routes, path) do
    segments = String.split(path, "/", trim: true)

    Enum.find_value(routes, :error, fn {pattern, handler} ->
      case match_segments(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = Enum.reverse(Module.get_attribute(env.module, :tiny_router_routes))
    compiled = Enum.map(routes, fn {path, handler} -> {compile_path(path), handler} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc "Returns `{:ok, handler, params}` for the first route that matches `path`, or `:error`."
      @spec match(String.t()) :: {:ok, module(), %{String.t() => String.t()}} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
      end
    end
  end

  defp expand_path!(path, _caller) when is_binary(path), do: path

  defp expand_path!(path, caller) do
    compile_error!(caller, "the path must be a string literal, got: #{Macro.to_string(path)}")
  end

  defp expand_handler!(handler, caller) do
    case Macro.expand(handler, caller) do
      module when is_atom(module) and module not in [nil, true, false] ->
        module

      _other ->
        description = "the handler must be a module name, got: #{Macro.to_string(handler)}"
        compile_error!(caller, description)
    end
  end

  defp compile_error!(caller, description) do
    raise CompileError, file: caller.file, line: caller.line, description: description
  end

  defp compile_path(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&compile_segment/1)
  end

  defp compile_segment(":" <> name), do: {:param, name}
  defp compile_segment(literal), do: literal

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
