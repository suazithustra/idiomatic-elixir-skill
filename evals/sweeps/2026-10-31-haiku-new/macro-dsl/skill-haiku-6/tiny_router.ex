defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

  Declare routes with `get/2` after `use TinyRouter`. Each route maps a path
  to a handler module. A segment that starts with `:` captures the request
  segment as a parameter.

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
      #=> {:ok, MyApp.UserHandler, %{id: "42"}}

      MyApp.Router.match("/missing")
      #=> :error
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route from `path` to `handler`.

  `path` must be a string and `handler` a module name. Any other value fails
  when the module compiles.
  """
  defmacro get(path, handler) do
    path = Macro.expand(path, __CALLER__)
    handler = Macro.expand(handler, __CALLER__)

    check_path!(path, __CALLER__)
    check_handler!(handler, __CALLER__)

    quote do
      TinyRouter.__put_route__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  def __put_route__(module, path, handler) do
    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  @doc false
  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(:tiny_router_routes)
      |> Enum.reverse()

    compiled = Enum.map(routes, fn {path, handler} -> {compile_path(path), handler} end)

    quote do
      @doc "Returns the declared routes as `{path, handler}` pairs, in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc "Matches `path` against the declared routes. Returns `{:ok, handler, params}` or `:error`."
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
      end
    end
  end

  @doc false
  def __match__(routes, path) do
    segments = String.split(path, "/", trim: true)

    Enum.find_value(routes, :error, fn {route, handler} ->
      case match_segments(route, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  # Checks run while the caller's module body expands, so the error points at
  # the `get` line in the caller's file.
  # Atoms nil, true and false are not module names, even though they are atoms.
  defguardp is_module_name(value) when is_atom(value) and value not in [nil, true, false]

  defp check_path!(path, _caller) when is_binary(path), do: :ok

  defp check_path!(path, caller) do
    message = "get/2 expects the path to be a string, got: #{Macro.to_string(path)}"
    raise_compile_error!(caller, message)
  end

  defp check_handler!(handler, _caller) when is_module_name(handler), do: :ok

  defp check_handler!(handler, caller) do
    message = "get/2 expects the handler to be a module name, got: #{Macro.to_string(handler)}"
    raise_compile_error!(caller, message)
  end

  defp raise_compile_error!(caller, description) do
    raise CompileError, file: caller.file, line: caller.line, description: description
  end

  defp compile_path(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&compile_segment/1)
  end

  defp compile_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp compile_segment(segment), do: {:static, segment}

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, name} | route], [segment | segments], params) do
    match_segments(route, segments, Map.put(params, name, segment))
  end

  defp match_segments([{:static, same} | route], [same | segments], params) do
    match_segments(route, segments, params)
  end

  defp match_segments(_route, _segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
