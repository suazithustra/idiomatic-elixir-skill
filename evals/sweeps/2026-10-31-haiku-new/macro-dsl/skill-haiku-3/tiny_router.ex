defmodule TinyRouter do
  @moduledoc """
  Declares request paths and the handler module for each one, then matches
  request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0` and
  > `match/1` in your module.

  ## Example

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{id: "42"}}
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
  Declares that requests for `path` are handled by `handler`.

  `path` must be a string, and `handler` must be a module name, both written
  literally in the source. A wrong value fails when the enclosing module
  compiles.
  """
  defmacro get(path, handler) do
    caller = __CALLER__
    path = Macro.expand(path, caller)
    handler = Macro.expand(handler, caller)

    validate_path!(path, caller)
    validate_handler!(handler, caller)

    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    table = Enum.map(routes, fn {path, handler} -> {pattern(path), handler} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc """
      Returns `{:ok, handler, params}` for the first declared route that matches
      `path`, or `:error` when none does. `params` maps each `:name` segment to
      the matching part of `path`.
      """
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(table)), path)
      end
    end
  end

  @doc false
  @spec __define__(module(), String.t(), module()) :: :ok
  def __define__(module, path, handler) do
    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  @doc false
  @spec __match__([{[String.t() | {:param, atom()}], module()}], String.t()) ::
          {:ok, module(), %{atom() => String.t()}} | :error
  def __match__(table, path) do
    segments = segments(path)
    Enum.find_value(table, :error, &match_route(&1, segments))
  end

  defp validate_path!(path, _caller) when is_binary(path), do: :ok

  defp validate_path!(path, caller) do
    compile_error!(
      caller,
      "get/2 expects the path to be a string such as \"/users/:id\", got: #{Macro.to_string(path)}"
    )
  end

  defp validate_handler!(handler, caller) do
    if module_name?(handler) do
      :ok
    else
      compile_error!(
        caller,
        "get/2 expects the handler to be a module name such as MyApp.PageHandler, got: #{Macro.to_string(handler)}"
      )
    end
  end

  defp module_name?(handler) do
    is_atom(handler) and String.starts_with?(Atom.to_string(handler), "Elixir.")
  end

  defp compile_error!(caller, description) do
    raise CompileError, file: caller.file, line: caller.line, description: description
  end

  defp segments(path), do: String.split(path, "/", trim: true)

  defp pattern(path) do
    path
    |> segments()
    |> Enum.map(&pattern_segment/1)
  end

  defp pattern_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp pattern_segment(literal), do: literal

  defp match_route({pattern, handler}, segments) do
    case match_segments(pattern, segments, %{}) do
      {:ok, params} -> {:ok, handler, params}
      :error -> nil
    end
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, name} | pattern], [value | segments], params) do
    match_segments(pattern, segments, Map.put(params, name, value))
  end

  defp match_segments([literal | pattern], [literal | segments], params) do
    match_segments(pattern, segments, params)
  end

  defp match_segments(_pattern, _segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
