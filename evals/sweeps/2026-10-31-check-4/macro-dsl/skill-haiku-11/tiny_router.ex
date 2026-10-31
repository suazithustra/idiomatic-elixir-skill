defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

  ## Usage

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

  `MyApp.Router.routes/0` returns the declared `{path, handler}` pairs in
  declaration order. `MyApp.Router.match/1` returns the first route that
  matches the request path.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0` and
  > `match/1` in your module. Nothing else is added to your module.

  Paths must be string literals and handlers must be module names written as
  aliases, such as `MyApp.PageHandler`. Anything else fails at compile time.
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

  Must be called in a module that does `use TinyRouter`.
  """
  defmacro get(path, handler) do
    path = Macro.expand_literals(path, __CALLER__)

    # Expanded as if inside a function: the router stores the handler and only
    # returns it, so the caller does not depend on the handler module at compile time.
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:call, 2}})

    check_route!(path, handler, __CALLER__)

    quote do
      @tiny_router_routes {unquote(path), unquote(handler)}
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    # Accumulated attributes are stored newest first.
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()

    quote do
      @doc "Returns the declared `{path, handler}` routes in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc "Returns `{:ok, handler, params}` for the first route that matches `path`, or `:error`."
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path) when is_binary(path), do: TinyRouter.__match__(routes(), path)
    end
  end

  @doc false
  @spec __match__([{String.t(), module()}], String.t()) ::
          {:ok, module(), %{atom() => String.t()}} | :error
  def __match__(routes, path) do
    segments = String.split(path, "/", trim: true)

    Enum.find_value(routes, :error, fn {route, handler} ->
      case match_segments(String.split(route, "/", trim: true), segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([":" <> name | route], [segment | path], params) do
    match_segments(route, path, Map.put(params, String.to_atom(name), segment))
  end

  defp match_segments([segment | route], [segment | path], params) do
    match_segments(route, path, params)
  end

  defp match_segments(_route, _path, _params), do: :error

  defp check_route!(path, handler, caller) do
    if not is_binary(path) do
      raise_compile_error!(caller, "route path must be a string, got: #{Macro.to_string(path)}")
    end

    if not module_name?(handler) do
      raise_compile_error!(
        caller,
        "route handler must be a module name, got: #{Macro.to_string(handler)}"
      )
    end
  end

  # Only alias-style atoms such as MyApp.PageHandler count as module names here.
  # Macro.classify_atom/1 returns :identifier for atoms like :lists, so
  # nil, true and Erlang module names are rejected too.
  defp module_name?(handler) do
    is_atom(handler) and Macro.classify_atom(handler) == :alias
  end

  defp raise_compile_error!(caller, message) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "TinyRouter: " <> message
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
