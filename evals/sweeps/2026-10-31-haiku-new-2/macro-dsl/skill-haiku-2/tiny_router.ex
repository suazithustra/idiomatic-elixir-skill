defmodule TinyRouter do
  @moduledoc """
  Declares `{path, handler}` routes in a module and matches request paths against them.

  ## Usage

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.routes()
      #=> [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{id: "42"}}

      MyApp.Router.match("/missing")
      #=> :error

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and, when your module compiles,
  > defines `routes/0` and `match/1`. Those two names are reserved in your module.
  """

  @doc """
  Declares a route. `path` must be a string literal and `handler` a module name.
  Both are checked when the calling module compiles.
  """
  defmacro get(path, handler) do
    path = validate_path!(path, __CALLER__)
    handler = validate_handler!(handler, __CALLER__)

    quote do
      @tiny_router_routes {unquote(path), unquote(handler)}
    end
  end

  @doc false
  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc "Matches a request path. Returns `{:ok, handler, params}` or `:error`."
      @spec match(String.t()) :: {:ok, module(), map()} | :error
      def match(path), do: TinyRouter.match_routes(routes(), path)
    end
  end

  @doc false
  @spec match_routes([{String.t(), module()}], String.t()) :: {:ok, module(), map()} | :error
  def match_routes(routes, path) when is_binary(path) do
    segments = split_path(path)

    Enum.find_value(routes, :error, &match_route(&1, segments))
  end

  defp validate_path!(path, _caller) when is_binary(path), do: path

  defp validate_path!(path, caller) do
    raise_compile_error!(
      caller,
      "route path must be a string literal such as \"/users/:id\", got: #{Macro.to_string(path)}"
    )
  end

  defp validate_handler!(handler, caller) do
    case Macro.expand(handler, caller) do
      module when is_atom(module) and module not in [nil, true, false] ->
        module

      _other ->
        raise_compile_error!(
          caller,
          "route handler must be a module name such as MyApp.PageHandler, got: #{Macro.to_string(handler)}"
        )
    end
  end

  defp raise_compile_error!(caller, description) do
    raise CompileError, file: caller.file, line: caller.line, description: description
  end

  defp match_route({pattern, handler}, segments) do
    case match_segments(split_path(pattern), segments, %{}) do
      {:ok, params} -> {:ok, handler, params}
      :error -> nil
    end
  end

  defp match_segments([], [], params), do: {:ok, params}

  # The atom set is fixed by the route declarations, so this does not grow with requests.
  defp match_segments([":" <> name | pattern], [segment | segments], params) do
    match_segments(pattern, segments, Map.put(params, String.to_atom(name), segment))
  end

  defp match_segments([segment | pattern], [segment | segments], params) do
    match_segments(pattern, segments, params)
  end

  defp match_segments(_pattern, _segments, _params), do: :error

  defp split_path(path), do: String.split(path, "/", trim: true)
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
