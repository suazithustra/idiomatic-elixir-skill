defmodule TinyRouter do
  @moduledoc """
  A tiny compile-time route table.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports the `get/2` macro and defines
  > `routes/0` and `match/1` in your module.

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

      MyApp.Router.match("/nope")
      #=> :error
  """

  @typedoc "A route segment: a literal string or a `:name` parameter."
  @type segment :: String.t() | {:param, atom()}

  @doc false
  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route from a literal path string to a handler module.

  Raises `CompileError` if the path is not a string literal starting with `/`,
  or the handler is not a module name.
  """
  defmacro get(path, handler) do
    path = validate_path!(path, __CALLER__)
    handler = validate_handler!(handler, __CALLER__)

    quote do
      @tiny_router_routes {unquote(path), unquote(handler)}
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    compiled = Enum.map(routes, fn {path, handler} -> {compile_path(path), handler} end)

    quote do
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
      end
    end
  end

  @doc false
  @spec __match__([{[segment()], module()}], String.t()) ::
          {:ok, module(), %{atom() => String.t()}} | :error
  def __match__(compiled_routes, path) do
    segments = split(path)

    Enum.find_value(compiled_routes, :error, fn {pattern, handler} ->
      case match_segments(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, name} | pattern], [value | rest], params) do
    match_segments(pattern, rest, Map.put(params, name, value))
  end

  defp match_segments([literal | pattern], [literal | rest], params) when is_binary(literal) do
    match_segments(pattern, rest, params)
  end

  defp match_segments(_pattern, _segments, _params), do: :error

  defp compile_path(path) do
    for segment <- split(path) do
      case segment do
        ":" <> name -> {:param, String.to_atom(name)}
        literal -> literal
      end
    end
  end

  defp split(path), do: String.split(path, "/", trim: true)

  defp validate_path!("/" <> _ = path, _caller), do: path

  defp validate_path!(path, caller) when is_binary(path) do
    compile_error!(caller, "route path must start with \"/\", got: #{inspect(path)}")
  end

  defp validate_path!(other, caller) do
    compile_error!(
      caller,
      "route path must be a string literal, got: #{Macro.to_string(other)}"
    )
  end

  # Expanding as if inside a function keeps the handler a runtime dependency only.
  defp validate_handler!(handler, caller) do
    case Macro.expand_literals(handler, %{caller | function: {:__routes__, 0}}) do
      module when is_atom(module) and module not in [nil, true, false] ->
        module

      _other ->
        compile_error!(
          caller,
          "route handler must be a module name, got: #{Macro.to_string(handler)}"
        )
    end
  end

  defp compile_error!(caller, description) do
    raise CompileError, file: caller.file, line: caller.line, description: description
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
