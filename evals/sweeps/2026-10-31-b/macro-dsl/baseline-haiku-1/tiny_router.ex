defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

  Segments that start with `:` capture the matching part of the request
  path. Params are returned as a map with string keys.
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route. `path` must be a string literal and `handler` must be a
  module name. Both are checked when the calling module compiles.
  """
  defmacro get(path_ast, handler_ast) do
    caller = __CALLER__
    path = Macro.expand(path_ast, caller)
    handler = Macro.expand(handler_ast, caller)

    unless is_binary(path) do
      compile_error!(
        caller,
        "path must be a string, got: #{Macro.to_string(path_ast)}"
      )
    end

    unless is_atom(handler) and handler not in [nil, true, false] do
      compile_error!(
        caller,
        "handler must be a module name, got: #{Macro.to_string(handler_ast)}"
      )
    end

    for segment <- segments(path), match?(":" <> _, segment) do
      name = String.trim_leading(segment, ":")

      unless name =~ ~r/\A[a-z_][a-zA-Z0-9_]*\z/ do
        compile_error!(caller, "invalid param name #{inspect(segment)} in path #{inspect(path)}")
      end
    end

    names = for ":" <> name <- segments(path), do: name

    if length(names) != length(Enum.uniq(names)) do
      compile_error!(caller, "duplicate param name in path #{inspect(path)}")
    end

    quote do
      @tiny_router_routes {unquote(path), unquote(handler)}
    end
  end

  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()

    clauses =
      for {path, handler} <- routes do
        {pattern, params} = route_pattern(path)

        quote do
          defp do_match(unquote(pattern)) do
            {:ok, unquote(handler), unquote(params)}
          end
        end
      end

    quote do
      def routes, do: unquote(Macro.escape(routes))

      def match(path) when is_binary(path) do
        path
        |> String.split("/", trim: true)
        |> do_match()
      end

      unquote_splicing(clauses)

      defp do_match(_segments), do: :error
    end
  end

  defp segments(path), do: String.split(path, "/", trim: true)

  # Turns a path such as "/users/:id" into a list pattern like ["users", id]
  # and a params map like %{"id" => id}.
  defp route_pattern(path) do
    segments = segments(path)

    pattern =
      Enum.map(segments, fn
        ":" <> name -> Macro.var(String.to_atom(name), nil)
        literal -> literal
      end)

    params =
      for ":" <> name <- segments do
        {name, Macro.var(String.to_atom(name), nil)}
      end

    {pattern, {:%{}, [], params}}
  end

  defp compile_error!(caller, description) do
    raise CompileError, file: caller.file, line: caller.line, description: "TinyRouter: " <> description
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
