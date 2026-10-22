defmodule TinyRouter do
  @moduledoc """
  A tiny compile-time router.

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.routes()
      #=> [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{"id" => "42"}}

      MyApp.Router.match("/nope")
      #=> :error

  Each route is compiled into a function clause that pattern matches on the
  path segments, so matching is done by the BEAM rather than by scanning a list.
  Routes are tried in declaration order. Paths and handlers are validated when
  the router module compiles.
  """

  @param_name ~r/^[a-z_][a-zA-Z0-9_]*$/

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

  `path` must be a string literal starting with `/`. Segments of the form
  `:name` are captured into the params map under the key `"name"`.
  `handler` must be a module name.
  """
  defmacro get(path, handler) do
    route = {validate_path!(path), validate_handler!(handler, __CALLER__)}

    quote do
      @tiny_router_routes unquote(Macro.escape(route))
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    clauses = Enum.map(routes, &match_clause/1)

    quote do
      @doc "Returns the declared `{path, handler}` routes in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc """
      Matches a request path against the declared routes.

      Returns `{:ok, handler, params}` for the first matching route, or `:error`.
      """
      @spec match(String.t()) :: {:ok, module(), %{optional(String.t()) => String.t()}} | :error
      def match(path) when is_binary(path) do
        path |> String.split("/", trim: true) |> __tiny_router_match__()
      end

      unquote_splicing(clauses)
      defp __tiny_router_match__(_segments), do: :error
    end
  end

  defp match_clause({path, handler}) do
    {patterns, params} =
      path
      |> String.split("/", trim: true)
      |> Enum.map_reduce([], fn
        ":" <> name, params ->
          var = Macro.var(String.to_atom(name), __MODULE__)
          {var, [{name, var} | params]}

        literal, params ->
          {literal, params}
      end)

    params = {:%{}, [], Enum.reverse(params)}

    quote do
      defp __tiny_router_match__(unquote(patterns)) do
        {:ok, unquote(handler), unquote(params)}
      end
    end
  end

  defp validate_path!("/" <> _ = path) do
    names =
      for ":" <> name <- String.split(path, "/", trim: true) do
        Regex.match?(@param_name, name) ||
          raise ArgumentError,
                "invalid parameter :#{name} in route #{inspect(path)}, " <>
                  "parameter names must start with a lowercase letter or underscore " <>
                  "and contain only letters, digits and underscores"

        name
      end

    case names -- Enum.uniq(names) do
      [] -> path
      [dup | _] -> raise ArgumentError, "parameter :#{dup} is used more than once in route #{inspect(path)}"
    end
  end

  defp validate_path!(path) when is_binary(path) do
    raise ArgumentError, "route path must start with \"/\", got: #{inspect(path)}"
  end

  defp validate_path!(path) do
    raise ArgumentError,
          "route path must be a string literal, got: #{Macro.to_string(path)}"
  end

  defp validate_handler!(handler, caller) do
    case Macro.expand(handler, caller) do
      module when is_atom(module) and module not in [nil, true, false] ->
        module

      _ ->
        raise ArgumentError,
              "route handler must be a module name, got: #{Macro.to_string(handler)}"
    end
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
