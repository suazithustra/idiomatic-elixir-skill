defmodule TinyRouter do
  @moduledoc """
  Declares a set of path-to-handler routes in a module.

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

  The module gets `routes/0`, which returns the declared `{path, handler}`
  pairs in declaration order, and `match/1`, which returns
  `{:ok, handler, params}` for the first route matching a request path, or
  `:error` when none matches.
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route for `path` (a string literal) that dispatches to `handler`
  (a module name).
  """
  defmacro get(path, handler) do
    path = expand_path!(path, __CALLER__)
    handler = expand_handler!(handler, __CALLER__)

    quote do
      @tiny_routes {unquote(path), unquote(handler)}
    end
  end

  defmacro __before_compile__(env) do
    pairs = env.module |> Module.get_attribute(:tiny_routes) |> Enum.reverse()
    compiled = Enum.map(pairs, fn {path, handler} -> {compile_path(path), handler} end)

    quote do
      def routes, do: unquote(Macro.escape(pairs))

      def match(path), do: TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
    end
  end

  @doc false
  def __match__(routes, path) do
    segments = String.split(path, "/", trim: true)

    Enum.find_value(routes, :error, fn {pattern, handler} ->
      case match_segments(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, name} | pattern], [segment | segments], params) do
    match_segments(pattern, segments, Map.put(params, name, segment))
  end

  defp match_segments([segment | pattern], [segment | segments], params) do
    match_segments(pattern, segments, params)
  end

  defp match_segments(_pattern, _segments, _params), do: :error

  defp compile_path(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(fn
      ":" <> name when name != "" -> {:param, String.to_atom(name)}
      segment -> segment
    end)
  end

  defp expand_path!(path_ast, caller) do
    case Macro.expand(path_ast, caller) do
      path when is_binary(path) ->
        path

      _ ->
        raise_error!(caller, "route path must be a string, got: #{Macro.to_string(path_ast)}")
    end
  end

  defp expand_handler!(handler_ast, caller) do
    case Macro.expand(handler_ast, caller) do
      handler when is_atom(handler) and handler not in [nil, true, false] ->
        handler

      _ ->
        raise_error!(
          caller,
          "route handler must be a module name, got: #{Macro.to_string(handler_ast)}"
        )
    end
  end

  defp raise_error!(caller, description) do
    raise CompileError, file: caller.file, line: caller.line, description: description
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
