defmodule TinyRouter do
  @moduledoc """
  A small DSL (domain-specific language) for declaring routes.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0` and
  > `match/1` in your module.

  ## Examples

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.routes()
      #=> [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{"id" => "42"}}

      MyApp.Router.match("/missing")
      #=> :error

  A path that is not a string starting with `/`, or a handler that is not a
  module name, raises a `CompileError` when the router module compiles.
  """

  @type route :: {String.t(), module()}

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

  Segments starting with `:` capture the request segment under that name.
  """
  defmacro get(path, handler) do
    # The handler is only stored, so expand it as if used inside a function.
    # That avoids a compile-time dependency on the handler module.
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:get, 2}})
    validate_route!(path, handler, __CALLER__)

    quote do
      @tiny_router_routes {unquote(path), unquote(handler)}
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()

    quote do
      @spec routes() :: [TinyRouter.route()]
      def routes, do: unquote(Macro.escape(routes))

      @spec match(String.t()) :: {:ok, module(), %{optional(String.t()) => String.t()}} | :error
      def match(path) when is_binary(path), do: TinyRouter.match(routes(), path)
    end
  end

  @doc false
  @spec match([route()], String.t()) ::
          {:ok, module(), %{optional(String.t()) => String.t()}} | :error
  def match(routes, path) do
    request_segments = split(path)

    Enum.find_value(routes, :error, fn {pattern, handler} ->
      case match_segments(split(pattern), request_segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp split(path), do: String.split(path, "/", trim: true)

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([":" <> name | pattern], [value | request], params) do
    match_segments(pattern, request, Map.put(params, name, value))
  end

  defp match_segments([segment | pattern], [segment | request], params) do
    match_segments(pattern, request, params)
  end

  defp match_segments(_pattern, _request, _params), do: :error

  defp validate_route!(path, handler, caller) do
    validate_path!(path, caller)
    validate_handler!(handler, caller)
  end

  defp validate_path!("/" <> _ = _path, _caller), do: :ok

  defp validate_path!(path, caller) when is_binary(path) do
    compile_error!(caller, "route path must start with \"/\", got: #{inspect(path)}")
  end

  defp validate_path!(path, caller) do
    compile_error!(caller, "route path must be a string, got: #{Macro.to_string(path)}")
  end

  defp validate_handler!(handler, _caller)
       when is_atom(handler) and handler not in [nil, true, false],
       do: :ok

  defp validate_handler!(handler, caller) do
    compile_error!(
      caller,
      "route handler must be a module name, got: #{Macro.to_string(handler)}"
    )
  end

  defp compile_error!(caller, description) do
    raise CompileError, file: caller.file, line: caller.line, description: description
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
