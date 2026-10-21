defmodule TinyRouter do
  @moduledoc """
  A minimal path router built from a declarative DSL.

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

  Routes are tried in declaration order and the first match wins. Segments
  starting with `:` capture the corresponding path segment into the params
  map, keyed by the name after the colon.

  Invalid routes (a path that is not a string, a handler that is not a module
  name, an unnamed or repeated `:param`) fail the compilation of the module
  that declares them.
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
  Declares a route that sends `path` to `handler`.

  `path` must evaluate to a string and `handler` to a module name.
  """
  defmacro get(path, handler) do
    # Expanding the alias as if inside a function keeps the handler a runtime
    # dependency, so editing a handler does not recompile the router.
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:match, 1}})
    location = Macro.Env.location(__CALLER__)

    quote do
      @tiny_router_routes TinyRouter.__route__!(
                            unquote(path),
                            unquote(handler),
                            unquote(location)
                          )
    end
  end

  @doc false
  def __route__!(path, handler, location) do
    unless is_binary(path) do
      compile_error!(location, "route path must be a string, got: #{inspect(path)}")
    end

    unless module_name?(handler) do
      compile_error!(
        location,
        "route handler must be a module name such as MyApp.PageHandler, got: #{inspect(handler)}"
      )
    end

    path
    |> param_names()
    |> Enum.reduce(MapSet.new(), fn
      "", _seen ->
        compile_error!(location, "route #{inspect(path)} has a \":\" segment with no name")

      name, seen ->
        if MapSet.member?(seen, name) do
          compile_error!(location, "route #{inspect(path)} uses :#{name} more than once")
        end

        MapSet.put(seen, name)
    end)

    {path, handler}
  end

  defp module_name?(atom) when is_atom(atom), do: match?("Elixir." <> _, Atom.to_string(atom))
  defp module_name?(_other), do: false

  defp param_names(path) do
    for ":" <> name <- segments(path), do: name
  end

  defp segments(path), do: String.split(path, "/", trim: true)

  defp compile_error!(location, message) do
    raise CompileError,
      file: location[:file],
      line: location[:line],
      description: "TinyRouter: " <> message
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    clauses = Enum.map(routes, &match_clause/1)

    quote do
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @spec match(String.t()) :: {:ok, module(), %{optional(String.t()) => String.t()}} | :error
      def match(path) when is_binary(path) do
        path |> String.split("/", trim: true) |> __tiny_router_match__()
      end

      unquote(clauses)
      defp __tiny_router_match__(_segments), do: :error
    end
  end

  # Builds one function clause per route, e.g. "/users/:id" becomes
  #
  #     defp __tiny_router_match__(["users", segment1]),
  #       do: {:ok, MyApp.UserHandler, %{"id" => segment1}}
  defp match_clause({path, handler}) do
    {pattern, params} =
      path
      |> segments()
      |> Enum.with_index()
      |> Enum.map_reduce([], fn
        {":" <> name, index}, params ->
          var = Macro.var(:"segment#{index}", __MODULE__)
          {var, [{name, var} | params]}

        {segment, _index}, params ->
          {segment, params}
      end)

    params = {:%{}, [], Enum.reverse(params)}

    quote do
      defp __tiny_router_match__(unquote(pattern)) do
        {:ok, unquote(handler), unquote(params)}
      end
    end
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
