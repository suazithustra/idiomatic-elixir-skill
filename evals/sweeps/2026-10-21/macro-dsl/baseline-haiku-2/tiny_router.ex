defmodule TinyRouter do
  @moduledoc """
  Declares `{path, handler}` routes in a module and matches request paths against them.

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

  `MyApp.Router.routes/0` returns the routes in declaration order.
  `MyApp.Router.match/1` returns `{:ok, handler, params}` or `:error`.
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route. `path` must be a string literal and `handler` a module name.
  """
  defmacro get(path, handler) do
    path = validate_path!(path, __CALLER__)
    handler = validate_handler!(handler, __CALLER__)

    quote do
      @tiny_routes {unquote(path), unquote(handler)}
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_routes) |> Enum.reverse()
    clauses = Enum.map(routes, &route_clause/1)

    quote do
      def routes, do: unquote(Macro.escape(routes))

      def match(path) when is_binary(path), do: do_match(TinyRouter.segments(path))
      def match(_path), do: :error

      unquote_splicing(clauses)
      defp do_match(_segments), do: :error
    end
  end

  @doc false
  def segments(path), do: String.split(path, "/", trim: true)

  defp validate_path!(path, caller) when is_binary(path) do
    params = for ":" <> name <- segments(path), do: name

    if Enum.any?(params, &(&1 == "")) do
      raise_at(caller, "path #{inspect(path)} has a parameter segment with no name")
    end

    if params != Enum.uniq(params) do
      raise_at(caller, "path #{inspect(path)} uses the same parameter name twice")
    end

    path
  end

  defp validate_path!(path, caller) do
    raise_at(caller, "path must be a string, got: #{Macro.to_string(path)}")
  end

  defp validate_handler!(handler, caller) do
    module = Macro.expand(handler, caller)

    if is_atom(module) and String.starts_with?(Atom.to_string(module), "Elixir.") do
      module
    else
      raise_at(caller, "handler must be a module name, got: #{Macro.to_string(handler)}")
    end
  end

  defp route_clause({path, handler}) do
    names = for ":" <> name <- segments(path), do: String.to_atom(name)
    pattern = Enum.map(segments(path), &segment_pattern/1)
    params = {:%{}, [], Enum.map(names, &{&1, Macro.var(&1, nil)})}

    quote do
      defp do_match(unquote(pattern)), do: {:ok, unquote(handler), unquote(params)}
    end
  end

  defp segment_pattern(":" <> name), do: Macro.var(String.to_atom(name), nil)
  defp segment_pattern(literal), do: literal

  defp raise_at(caller, description) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "TinyRouter: " <> description
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
