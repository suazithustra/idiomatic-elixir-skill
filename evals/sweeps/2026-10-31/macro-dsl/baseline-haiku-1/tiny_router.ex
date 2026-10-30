defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module with `get/2`.

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

  Generates `routes/0`, which returns `{path, handler}` pairs in declaration
  order, and `match/1`, which returns `{:ok, handler, params}` or `:error`.
  Params are keyed by string name, e.g. `%{"id" => "42"}`.

  Invalid declarations raise a `CompileError` when the router module compiles.
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  defmacro get(path, handler) do
    path = validate_path!(path, __CALLER__)
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
      def routes, do: unquote(Macro.escape(routes))

      def match(path) when is_binary(path) do
        segments = String.split(path, "/", trim: true)

        Enum.find_value(unquote(Macro.escape(compiled)), :error, fn {pattern, handler} ->
          case TinyRouter.match_segments(pattern, segments, %{}) do
            {:ok, params} -> {:ok, handler, params}
            :error -> nil
          end
        end)
      end
    end
  end

  @doc false
  def match_segments([], [], params), do: {:ok, params}

  def match_segments([{:literal, s} | pattern], [s | segments], params),
    do: match_segments(pattern, segments, params)

  def match_segments([{:param, name} | pattern], [value | segments], params),
    do: match_segments(pattern, segments, Map.put(params, name, value))

  def match_segments(_pattern, _segments, _params), do: :error

  defp compile_path(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(fn
      ":" <> name -> {:param, name}
      literal -> {:literal, literal}
    end)
  end

  defp validate_path!(path, caller) do
    unless is_binary(path) do
      raise CompileError,
        description: "TinyRouter: route path must be a string literal, got: #{Macro.to_string(path)}",
        file: caller.file,
        line: caller.line
    end

    path
  end

  defp validate_handler!(handler, caller) do
    expanded = Macro.expand(handler, caller)

    unless is_module_name?(expanded) do
      raise CompileError,
        description: "TinyRouter: route handler must be a module name, got: #{Macro.to_string(handler)}",
        file: caller.file,
        line: caller.line
    end

    expanded
  end

  defp is_module_name?(atom) when is_atom(atom) and not is_nil(atom),
    do: String.starts_with?(Atom.to_string(atom), "Elixir.")

  defp is_module_name?(_), do: false
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
