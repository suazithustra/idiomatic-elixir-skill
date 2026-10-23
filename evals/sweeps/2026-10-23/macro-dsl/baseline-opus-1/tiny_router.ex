defmodule TinyRouter do
  @moduledoc """
  A tiny router whose routes are compiled into pattern-matching clauses.

  Declare routes with `get/2` after `use TinyRouter`:

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

  The router module then defines:

    * `routes/0` - the declared `{path, handler}` pairs, in declaration order.
    * `match/1` - matches a request path and returns `{:ok, handler, params}`
      or `:error`. `params` maps each `:name` segment, as a string key, to the
      matching segment of the request path.

  Routes are tried in declaration order, so the first matching route wins.
  Paths must be string literals and handlers must be module names; anything
  else raises when the router module compiles.
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
  Declares a route from `path` to the `handler` module.

  A segment starting with `:` captures the matching request segment, so
  `get "/users/:id", MyApp.UserHandler` matches `"/users/42"` with params
  `%{"id" => "42"}`.
  """
  defmacro get(path, handler) do
    validate_path!(path)
    handler = expand_handler!(handler, __CALLER__)

    quote do
      @tiny_router_routes {unquote(path), unquote(handler)}
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()

    quote do
      @doc "Returns the declared `{path, handler}` routes in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc """
      Matches `path` against the declared routes, in declaration order.

      Returns `{:ok, handler, params}` for the first matching route, or `:error`.
      """
      @spec match(String.t()) :: {:ok, module(), %{optional(String.t()) => String.t()}} | :error
      def match(path) when is_binary(path) do
        path |> String.split("/", trim: true) |> __tiny_router_match__()
      end

      unquote(Enum.map(routes, &match_clause/1))
      defp __tiny_router_match__(_segments), do: :error
    end
  end

  defp match_clause({path, handler}) do
    {pattern, params} =
      path
      |> String.split("/", trim: true)
      |> Enum.map_reduce([], fn
        ":" <> name, params ->
          var = Macro.unique_var(:param, __MODULE__)
          {var, [{name, var} | params]}

        static, params ->
          {static, params}
      end)

    quote do
      defp __tiny_router_match__(unquote(pattern)) do
        {:ok, unquote(handler), unquote({:%{}, [], params})}
      end
    end
  end

  defp validate_path!(path) when is_binary(path) do
    names = for ":" <> name <- String.split(path, "/", trim: true), do: name

    cond do
      "" in names ->
        raise ArgumentError, "route path #{inspect(path)} has a \":\" segment with no parameter name"

      names != Enum.uniq(names) ->
        raise ArgumentError, "route path #{inspect(path)} uses the same parameter name more than once"

      true ->
        :ok
    end
  end

  defp validate_path!(path) do
    raise ArgumentError,
          "expected the route path to be a string literal, got: #{Macro.to_string(path)}"
  end

  # Expanding as if inside a function keeps the handler a runtime dependency,
  # so the router does not recompile whenever a handler changes.
  defp expand_handler!(handler, env) do
    case Macro.expand(handler, %{env | function: {:match, 1}}) do
      module when is_atom(module) and module not in [nil, true, false] ->
        module

      _other ->
        raise ArgumentError,
              "expected the route handler to be a module name, got: #{Macro.to_string(handler)}"
    end
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
