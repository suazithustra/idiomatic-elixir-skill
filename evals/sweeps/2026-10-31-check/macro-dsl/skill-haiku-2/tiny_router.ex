defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and, when the module
  > compiles, defines `routes/0` and `match/1` in it.

  ## Example

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

  @doc """
  Declares a route.

  `path` must be a string literal and `handler` a module name. Anything else
  stops the calling module from compiling.
  """
  defmacro get(path, handler) do
    path = Macro.expand_literals(path, __CALLER__)
    handler = Macro.expand_literals(handler, __CALLER__)

    if not is_binary(path) do
      compile_error!(__CALLER__, "route path must be a string, got: #{Macro.to_string(path)}")
    end

    if not is_atom(handler) do
      compile_error!(
        __CALLER__,
        "route handler must be a module name, got: #{Macro.to_string(handler)}"
      )
    end

    quote do
      @routes {unquote(path), unquote(handler)}
    end
  end

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:routes) |> Enum.reverse()

    quote do
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @spec match(String.t()) :: {:ok, module(), map()} | :error
      def match(path), do: TinyRouter.__match__(routes(), path)
    end
  end

  @doc false
  @spec __match__([{String.t(), module()}], String.t()) :: {:ok, module(), map()} | :error
  def __match__(routes, path) do
    request_segments = split_path(path)

    Enum.find_value(routes, :error, fn {pattern, handler} ->
      case match_segments(split_path(pattern), request_segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp compile_error!(env, description) do
    raise CompileError, file: env.file, line: env.line, description: description
  end

  defp split_path(path), do: String.split(path, "/", trim: true)

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([":" <> name | pattern], [segment | segments], params) do
    match_segments(pattern, segments, Map.put(params, String.to_atom(name), segment))
  end

  defp match_segments([segment | pattern], [segment | segments], params) do
    match_segments(pattern, segments, params)
  end

  defp match_segments(_pattern, _segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
