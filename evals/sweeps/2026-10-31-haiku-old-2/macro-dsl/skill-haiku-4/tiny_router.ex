defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

  ## Usage

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{id: "42"}}

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0`
  > and `match/1` in your module.
  """

  @typep segment :: {:literal, String.t()} | {:param, atom()}

  @doc """
  Declares a route. The path must be a string literal and the handler must
  be a module name. Both are checked when the calling module compiles.
  """
  defmacro get(path, handler) do
    path = validate_path!(path, __CALLER__)
    handler = validate_handler!(handler, __CALLER__)

    quote do
      TinyRouter.__put_route__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    entries = env.module |> Module.get_attribute(:tiny_routes) |> Enum.reverse()
    pairs = Enum.map(entries, fn {path, handler, _pattern} -> {path, handler} end)

    quote do
      @doc """
      Returns the declared `{path, handler}` pairs in declaration order.
      """
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(pairs))

      @doc """
      Returns `{:ok, handler, params}` for the first route that matches `path`,
      or `:error` when none does.
      """
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(entries)), path)
      end
    end
  end

  @doc false
  @spec __put_route__(module(), String.t(), module()) :: :ok
  def __put_route__(module, path, handler) do
    Module.put_attribute(module, :tiny_routes, {path, handler, parse_path(path)})
  end

  @doc false
  @spec __match__([{String.t(), module(), [segment()]}], String.t()) ::
          {:ok, module(), %{atom() => String.t()}} | :error
  def __match__(entries, path) do
    segments = split(path)
    Enum.find_value(entries, :error, &match_route(&1, segments))
  end

  defp match_route({_path, handler, pattern}, segments) do
    case match_segments(pattern, segments, %{}) do
      {:ok, params} -> {:ok, handler, params}
      :error -> nil
    end
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:literal, word} | pattern], [word | segments], params) do
    match_segments(pattern, segments, params)
  end

  defp match_segments([{:param, name} | pattern], [value | segments], params) do
    match_segments(pattern, segments, Map.put(params, name, value))
  end

  defp match_segments(_pattern, _segments, _params), do: :error

  @spec parse_path(String.t()) :: [segment()]
  defp parse_path(path) do
    for segment <- split(path) do
      case segment do
        # Route text comes from source code, not from requests, so the set of
        # atoms created here is fixed at compile time.
        ":" <> name -> {:param, String.to_atom(name)}
        literal -> {:literal, literal}
      end
    end
  end

  defp split(path), do: String.split(path, "/", trim: true)

  defp validate_path!(path, _env) when is_binary(path), do: path

  defp validate_path!(path, env) do
    compile_error!(env, "get/2 expects the path to be a string, got: #{Macro.to_string(path)}")
  end

  defp validate_handler!(handler, env) do
    # Expanding as if inside a function keeps the handler module out of the
    # compile-time dependencies of the calling module.
    expanded = Macro.expand_literals(handler, %{env | function: {:call, 2}})

    if is_atom(expanded) and expanded not in [nil, true, false] do
      expanded
    else
      compile_error!(
        env,
        "get/2 expects the handler to be a module name, got: #{Macro.to_string(handler)}"
      )
    end
  end

  defp compile_error!(env, description) do
    raise CompileError, file: env.file, line: env.line, description: description
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
