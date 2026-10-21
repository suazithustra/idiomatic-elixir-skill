defmodule TinyRouter do
  @moduledoc """
  A tiny compile-time route table.

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.routes()
      #=> [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{"id" => "42"}}

  Paths must be string literals starting with `/`, and handlers must be
  module names. Anything else raises a `CompileError` when the router compiles.
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc "Declares a route for `path` handled by the module `handler`."
  defmacro get(path, handler) do
    handler = Macro.expand(handler, __CALLER__)
    validate!(path, handler, __CALLER__)

    quote do
      @tiny_router_routes {unquote(path), unquote(handler)}
    end
  end

  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc """
      Matches a request path against the declared routes.

      Returns `{:ok, handler, params}` or `:error`.
      """
      @spec match(String.t()) :: {:ok, module(), %{optional(String.t()) => String.t()}} | :error
      def match(path), do: TinyRouter.match(routes(), path)
    end
  end

  @doc false
  def match(routes, path) when is_binary(path) do
    request = segments(path)

    Enum.find_value(routes, :error, fn {pattern, handler} ->
      case match_segments(segments(pattern), request, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  def match(_routes, _path), do: :error

  defp segments(path), do: String.split(path, "/", trim: true)

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([":" <> name | pattern], [value | request], params),
    do: match_segments(pattern, request, Map.put(params, name, value))

  defp match_segments([segment | pattern], [segment | request], params),
    do: match_segments(pattern, request, params)

  defp match_segments(_pattern, _request, _params), do: :error

  defp validate!(path, handler, caller) do
    cond do
      not is_binary(path) ->
        compile_error!(caller, "route path must be a string literal, got: #{Macro.to_string(path)}")

      not String.starts_with?(path, "/") ->
        compile_error!(caller, ~s(route path must start with "/", got: #{inspect(path)}))

      not module_name?(handler) ->
        compile_error!(
          caller,
          "route handler must be a module name (e.g. MyApp.PageHandler), got: #{Macro.to_string(handler)}"
        )

      true ->
        :ok
    end
  end

  defp module_name?(handler), do: is_atom(handler) and handler not in [nil, true, false]

  defp compile_error!(caller, description) do
    raise CompileError, file: caller.file, line: caller.line, description: description
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
