defmodule TinyRouter do
  @moduledoc """
  Declares request routes in a module and matches request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0` and
  > `match/1` in your module.

  A path is split on `/`. A segment that starts with `:` matches any request
  segment and is returned as a param:

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.match("/users/42")
      # {:ok, MyApp.UserHandler, %{id: "42"}}
  """

  defguardp is_module_name(value) when is_atom(value) and value not in [nil, true, false]

  @doc false
  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route from `path` to `handler`. Routes match in declaration order.
  """
  defmacro get(path, handler) do
    quote do
      TinyRouter.__put_route__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  @spec __put_route__(module(), term(), term()) :: :ok
  def __put_route__(module, path, handler) when is_binary(path) and is_module_name(handler) do
    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  def __put_route__(module, path, _handler) when not is_binary(path) do
    raise ArgumentError,
          "#{inspect(module)}: route path must be a string, got: #{inspect(path)}"
  end

  def __put_route__(module, path, handler) do
    raise ArgumentError,
          "#{inspect(module)}: handler for #{inspect(path)} must be a module name, " <>
            "got: #{inspect(handler)}"
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    match_clauses = Enum.map(routes, &match_clause/1)

    quote do
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @spec match(String.t()) :: {:ok, module(), map()} | :error
      def match(path) when is_binary(path) do
        path
        |> String.split("/", trim: true)
        |> match_segments()
      end

      unquote_splicing(match_clauses)

      defp match_segments(_segments), do: :error
    end
  end

  defp match_clause({path, handler}) do
    segments = String.split(path, "/", trim: true)
    {patterns, params} = Enum.map_reduce(segments, [], &segment_pattern/2)

    quote do
      defp match_segments(unquote(patterns)) do
        {:ok, unquote(handler), %{unquote_splicing(params)}}
      end
    end
  end

  defp segment_pattern(":" <> name, params) do
    key = String.to_atom(name)
    var = Macro.var(key, __MODULE__)
    {var, [{key, var} | params]}
  end

  defp segment_pattern(literal, params), do: {literal, params}
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
