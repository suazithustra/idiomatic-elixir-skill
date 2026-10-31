defmodule TinyRouter do
  @moduledoc """
  A small router DSL. A module that calls `use TinyRouter` declares routes
  with `get/2`. Each route is checked at compile time.

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

  `routes/0` returns the `{path, handler}` pairs in declaration order.
  `match/1` takes a request path and returns `{:ok, handler, params}` or `:error`.
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route. `path` must be a string literal. `handler` must be a
  module name, such as `MyApp.PageHandler`.
  """
  defmacro get(path, handler) do
    path = expand_path!(path, __CALLER__)
    handler = expand_handler!(handler, __CALLER__)

    quote do
      @tiny_router_routes {unquote(path), unquote(handler)}
    end
  end

  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(:tiny_router_routes)
      |> Enum.reverse()

    compiled = Enum.map(routes, fn {path, handler} -> {handler, compile_pattern(path)} end)

    quote do
      def routes, do: unquote(Macro.escape(routes))

      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
      end

      def match(_path), do: :error
    end
  end

  @doc false
  def __match__(compiled, path) do
    segments = split(path)

    Enum.find_value(compiled, :error, fn {handler, pattern} ->
      case bind(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp split(path), do: String.split(path, "/", trim: true)

  defp compile_pattern(path) do
    path
    |> split()
    |> Enum.map(fn
      ":" <> name when name != "" -> {:param, String.to_atom(name)}
      segment -> segment
    end)
  end

  defp bind([], [], params), do: {:ok, params}

  defp bind([{:param, name} | pattern], [value | segments], params) do
    bind(pattern, segments, Map.put(params, name, value))
  end

  defp bind([literal | pattern], [literal | segments], params) do
    bind(pattern, segments, params)
  end

  defp bind(_pattern, _segments, _params), do: :error

  defp expand_path!(path, caller) do
    case Macro.expand(path, caller) do
      value when is_binary(value) ->
        value

      _ ->
        raise_compile_error!(
          caller,
          "get/2 expects a path string, such as \"/users/:id\", got: #{Macro.to_string(path)}"
        )
    end
  end

  defp expand_handler!(handler, caller) do
    case Macro.expand(handler, caller) do
      module when is_atom(module) and module not in [nil, true, false] ->
        if module_name?(module) do
          module
        else
          raise_handler_error!(handler, caller)
        end

      _ ->
        raise_handler_error!(handler, caller)
    end
  end

  defp module_name?(atom), do: String.starts_with?(Atom.to_string(atom), "Elixir.")

  defp raise_handler_error!(handler, caller) do
    raise_compile_error!(
      caller,
      "get/2 expects a handler module name, such as MyApp.PageHandler, got: " <>
        Macro.to_string(handler)
    )
  end

  defp raise_compile_error!(caller, description) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: description
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
