defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

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

  `use TinyRouter` imports `get/2` and defines `routes/0` and `match/1`
  in the caller.
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route. `path` must be a string literal and `handler` a module name.
  """
  defmacro get(path, handler) do
    path = Macro.expand(path, __CALLER__)
    handler = Macro.expand(handler, __CALLER__)

    if not is_binary(path) do
      compile_error!(__CALLER__, "route path must be a string, got: #{Macro.to_string(path)}")
    end

    if not module_name?(handler) do
      compile_error!(
        __CALLER__,
        "route handler must be a module name, got: #{Macro.to_string(handler)}"
      )
    end

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
      |> Enum.map(fn {path, handler} -> {path, handler, segments(path)} end)

    public_routes = Enum.map(routes, fn {path, handler, _segments} -> {path, handler} end)

    quote do
      def routes, do: unquote(Macro.escape(public_routes))

      def match(path), do: TinyRouter.__match__(unquote(Macro.escape(routes)), path)
    end
  end

  @doc false
  def __match__(routes, path) when is_binary(path) do
    request = String.split(path, "/", trim: true)

    Enum.find_value(routes, :error, fn {_path, handler, pattern} ->
      case match_segments(pattern, request, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp module_name?(handler), do: is_atom(handler) and handler not in [nil, true, false]

  defp compile_error!(env, description) do
    raise CompileError, file: env.file, line: env.line, description: description
  end

  # Splits the pattern once at compile time so matching never creates atoms.
  defp segments(path) do
    for segment <- String.split(path, "/", trim: true) do
      case segment do
        ":" <> name -> {:param, String.to_atom(name)}
        literal -> {:literal, literal}
      end
    end
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:literal, same} | pattern], [same | request], params),
    do: match_segments(pattern, request, params)

  defp match_segments([{:param, name} | pattern], [value | request], params),
    do: match_segments(pattern, request, Map.put(params, name, value))

  defp match_segments(_pattern, _request, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
