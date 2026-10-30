defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

  `use TinyRouter` imports `get/2` and defines `routes/0` and `match/1`
  in the calling module. Paths must be string literals and handlers must
  be module names. Both are checked when the router module compiles.

  ## Usage

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

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)

      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route from `path` to `handler`.

  `path` must be a string literal and `handler` a module name.
  """
  defmacro get(path, handler) do
    path = Macro.expand(path, __CALLER__)
    handler = Macro.expand(handler, __CALLER__)

    quote do
      TinyRouter.__put_route__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  @spec __put_route__(module(), term(), term()) :: :ok
  def __put_route__(module, path, handler) do
    if not is_binary(path) do
      invalid!(module, "route path must be a string, got: #{inspect(path)}")
    end

    names = param_names(path)

    if "" in names or Enum.uniq(names) != names do
      invalid!(module, "route path has an empty or repeated parameter name: #{inspect(path)}")
    end

    if not module_name?(handler) do
      invalid!(module, "handler must be a module name, got: #{inspect(handler)}")
    end

    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    clauses = Enum.map(routes, &match_clause/1)

    quote do
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @spec match(String.t()) :: {:ok, module(), map()} | :error
      def match(path) when is_binary(path), do: match_segments(TinyRouter.split(path))

      unquote_splicing(clauses)

      defp match_segments(_segments), do: :error
    end
  end

  @doc false
  @spec split(String.t()) :: [String.t()]
  def split(path), do: String.split(path, "/", trim: true)

  defp invalid!(module, message) do
    raise ArgumentError, "#{inspect(module)}: #{message}"
  end

  defp module_name?(value), do: is_atom(value) and value not in [nil, true, false]

  defp param_names(path) do
    for ":" <> name <- split(path), do: name
  end

  defp param_var(name), do: Macro.var(String.to_atom(name), __MODULE__)

  defp match_clause({path, handler}) do
    pattern = path |> split() |> Enum.map(&segment_pattern/1)
    params = for name <- param_names(path), do: {String.to_atom(name), param_var(name)}

    quote do
      defp match_segments(unquote(pattern)) do
        {:ok, unquote(handler), unquote({:%{}, [], params})}
      end
    end
  end

  defp segment_pattern(":" <> name), do: param_var(name)
  defp segment_pattern(literal), do: literal
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
