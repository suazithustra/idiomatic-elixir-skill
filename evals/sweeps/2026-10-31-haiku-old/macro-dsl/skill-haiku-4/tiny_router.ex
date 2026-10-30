defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0`
  > and `match/1` in your module. Invalid routes fail when the module compiles.

  A segment that starts with `:` captures that part of the request path,
  so `"/users/:id"` matches `"/users/42"` with `%{id: "42"}`.

  ## Examples

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{id: "42"}}
  """

  @doc false
  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route. Use it in the body of a module that calls `use TinyRouter`.
  """
  defmacro get(path, handler) do
    quote location: :keep do
      TinyRouter.__put_route__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  @spec __put_route__(module(), term(), term()) :: :ok
  def __put_route__(module, path, handler) do
    validate_path!(path)
    validate_handler!(handler)
    Module.put_attribute(module, :tiny_routes, {path, handler})
  end

  @doc false
  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(:tiny_routes)
      |> Enum.reverse()

    route_definitions(routes)
  end

  defp route_definitions(routes) do
    clauses = Enum.map(routes, fn {path, handler} -> segment_clause(path, handler) end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc "Returns `{:ok, handler, params}` for the first route matching `path`, or `:error`."
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path) when is_binary(path) do
        match_segments(String.split(path, "/", trim: true))
      end

      unquote_splicing(clauses)

      defp match_segments(_segments), do: :error
    end
  end

  defp segment_clause(path, handler) do
    segments = parse_segments(path)

    pattern =
      Enum.map(segments, fn
        {:literal, text} -> text
        {:param, name} -> Macro.var(name, nil)
      end)

    params = for {:param, name} <- segments, do: {name, Macro.var(name, nil)}

    quote do
      defp match_segments(unquote(pattern)) do
        {:ok, unquote(handler), unquote({:%{}, [], params})}
      end
    end
  end

  defp parse_segments(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(fn
      ":" <> name -> {:param, String.to_atom(name)}
      literal -> {:literal, literal}
    end)
  end

  defp validate_path!(path) do
    if not is_binary(path) do
      raise ArgumentError, "TinyRouter: route path must be a string, got: #{inspect(path)}"
    end

    names = for {:param, name} <- parse_segments(path), do: name

    Enum.each(names, fn name ->
      if not Regex.match?(~r/\A[a-z_][a-zA-Z0-9_]*\z/, Atom.to_string(name)) do
        raise ArgumentError, "TinyRouter: invalid parameter :#{name} in #{inspect(path)}"
      end
    end)

    if length(names) != length(Enum.uniq(names)) do
      raise ArgumentError, "TinyRouter: duplicate parameter name in #{inspect(path)}"
    end
  end

  defp validate_handler!(handler) do
    if not (is_atom(handler) and String.starts_with?(Atom.to_string(handler), "Elixir.")) do
      raise ArgumentError,
            "TinyRouter: handler must be a module name, got: #{inspect(handler)}"
    end
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
