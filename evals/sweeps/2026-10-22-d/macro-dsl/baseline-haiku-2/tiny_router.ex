defmodule TinyRouter do
  @moduledoc """
  A tiny compile-time router DSL.

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

  Routes are validated when the router module compiles. Paths must be string
  literals and handlers must be module names.
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc "Declares a route for `path` that dispatches to `handler`."
  defmacro get(path, handler) do
    validate_path!(path, __CALLER__)
    handler = validate_handler!(handler, __CALLER__)

    quote do
      @tiny_router_routes {unquote(path), unquote(handler)}
    end
  end

  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(:tiny_router_routes)
      |> Enum.reverse()

    compiled =
      Enum.map(routes, fn {path, handler} -> {compile_path(path), handler} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      def routes, do: unquote(Macro.escape(routes))

      @doc "Matches a request path, returning `{:ok, handler, params}` or `:error`."
      def match(path) when is_binary(path) do
        segments = TinyRouter.split_path(path)

        Enum.find_value(unquote(Macro.escape(compiled)), :error, fn {pattern, handler} ->
          case TinyRouter.bind(pattern, segments, %{}) do
            {:ok, params} -> {:ok, handler, params}
            :error -> nil
          end
        end)
      end
    end
  end

  @doc false
  def split_path(path), do: String.split(path, "/", trim: true)

  @doc false
  def compile_path(path) do
    Enum.map(split_path(path), fn
      ":" <> name -> {:param, name}
      segment -> {:static, segment}
    end)
  end

  @doc false
  def bind([], [], params), do: {:ok, params}

  def bind([{:static, segment} | patterns], [segment | segments], params) do
    bind(patterns, segments, params)
  end

  def bind([{:param, name} | patterns], [value | segments], params) do
    bind(patterns, segments, Map.put(params, name, value))
  end

  def bind(_patterns, _segments, _params), do: :error

  defp validate_path!(path, _caller) when is_binary(path), do: path

  defp validate_path!(path, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "TinyRouter: route path must be a string literal, got: #{Macro.to_string(path)}"
  end

  defp validate_handler!(handler, caller) do
    expanded = Macro.expand(handler, caller)

    if is_atom(expanded) and String.starts_with?(Atom.to_string(expanded), "Elixir.") do
      expanded
    else
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description:
          "TinyRouter: route handler must be a module name, got: #{Macro.to_string(handler)}"
    end
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
