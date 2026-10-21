defmodule TinyRouter do
  @moduledoc """
  A small DSL (domain-specific language) for declaring routes and matching
  request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports the `get/2` macro and defines
  > `routes/0` and `match/1` in your module.

  ## Example

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

  Paths and handlers must be written literally: the path as a string starting
  with `/`, the handler as a module name. Anything else raises a
  `CompileError` when the router module compiles. Params are returned with
  string keys, since their values come from the request.
  """

  @type segment :: String.t() | {:param, String.t()}
  @type route :: {path :: String.t(), handler :: module(), pattern :: [segment()]}

  @doc false
  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route. `path` must be a string literal starting with `/`, and
  `handler` a module name. Segments starting with `:` match any value and are
  returned as params.
  """
  defmacro get(path, handler) do
    # The handler is only stored, never called here, so expand it as if it
    # were used inside a function to avoid a compile-time dependency on it.
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:match, 1}})

    validate_path!(path, __CALLER__)
    validate_handler!(handler, __CALLER__)

    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    declared = for {path, handler, _pattern} <- routes, do: {path, handler}

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(declared))

      @doc """
      Matches a request path against the declared routes.

      Returns `{:ok, handler, params}` for the first matching route, or
      `:error`.
      """
      @spec match(String.t()) :: {:ok, module(), %{optional(String.t()) => String.t()}} | :error
      def match(request_path) when is_binary(request_path) do
        TinyRouter.__match__(unquote(Macro.escape(routes)), request_path)
      end
    end
  end

  @doc false
  @spec __define__(module(), String.t(), module()) :: :ok
  def __define__(module, path, handler) do
    Module.put_attribute(module, :tiny_router_routes, {path, handler, parse_pattern(path)})
  end

  @doc false
  @spec __match__([route()], String.t()) ::
          {:ok, module(), %{optional(String.t()) => String.t()}} | :error
  def __match__(routes, request_path) do
    segments = split(request_path)

    Enum.find_value(routes, :error, fn {_path, handler, pattern} ->
      case match_segments(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp validate_path!("/" <> _ = _path, _caller), do: :ok

  defp validate_path!(path, caller) when is_binary(path) do
    compile_error!(caller, "route path must start with \"/\", got: #{inspect(path)}")
  end

  defp validate_path!(path, caller) do
    compile_error!(
      caller,
      "route path must be a string literal, got: #{Macro.to_string(path)}"
    )
  end

  defp validate_handler!(handler, _caller)
       when is_atom(handler) and handler not in [nil, true, false],
       do: :ok

  defp validate_handler!(handler, caller) do
    compile_error!(
      caller,
      "route handler must be a module name such as MyApp.PageHandler, " <>
        "got: #{Macro.to_string(handler)}"
    )
  end

  defp compile_error!(caller, description) do
    raise CompileError, file: caller.file, line: caller.line, description: description
  end

  defp parse_pattern(path) do
    for segment <- split(path) do
      case segment do
        ":" <> name -> {:param, name}
        literal -> literal
      end
    end
  end

  defp split(path), do: String.split(path, "/", trim: true)

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, name} | pattern], [value | segments], params) do
    match_segments(pattern, segments, Map.put(params, name, value))
  end

  defp match_segments([literal | pattern], [literal | segments], params)
       when is_binary(literal) do
    match_segments(pattern, segments, params)
  end

  defp match_segments(_pattern, _segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
