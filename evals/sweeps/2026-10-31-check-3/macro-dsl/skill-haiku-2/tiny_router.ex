defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{id: "42"}}

  Paths must be strings and handlers must be module names. Anything else
  fails when the router module compiles.
  """

  @doc """
  Declares a route from `path` to `handler`.

  Routes are returned by `routes/0` in the order they are declared.
  """
  defmacro get(path, handler) do
    # The handler is only used at runtime, so expand it as if it sat inside
    # a function. Otherwise the router would recompile whenever it changes.
    env = %{__CALLER__ | function: {:call, 2}}
    path = Macro.expand_literals(path, env)
    handler = Macro.expand_literals(handler, env)

    validate_path!(path, __CALLER__)
    validate_handler!(handler, __CALLER__)

    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  @spec __define__(module(), String.t(), module()) :: :ok
  def __define__(module, path, handler) do
    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  @doc false
  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(:tiny_router_routes)
      |> Enum.reverse()

    compiled = Enum.map(routes, fn {path, handler} -> {segments(path), handler} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc "Returns `{:ok, handler, params}` for the first route that matches `path`, or `:error`."
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path), do: TinyRouter.__match__(path, unquote(Macro.escape(compiled)))
    end
  end

  @doc false
  @spec __match__(String.t(), [{[term()], module()}]) :: {:ok, module(), map()} | :error
  def __match__(path, compiled) do
    segments = String.split(path, "/", trim: true)

    Enum.find_value(compiled, :error, fn {pattern, handler} ->
      case match_segments(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, name} | pattern], [value | segments], params) do
    match_segments(pattern, segments, Map.put(params, name, value))
  end

  defp match_segments([literal | pattern], [literal | segments], params) do
    match_segments(pattern, segments, params)
  end

  defp match_segments(_pattern, _segments, _params), do: :error

  defp segments(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&segment/1)
  end

  defp segment(":" <> name), do: {:param, String.to_atom(name)}
  defp segment(literal), do: literal

  defp validate_path!(path, _caller) when is_binary(path), do: :ok

  defp validate_path!(path, caller) do
    fail!(caller, "route path must be a string, got: #{Macro.to_string(path)}")
  end

  defp validate_handler!(handler, caller) do
    if module_name?(handler) do
      :ok
    else
      fail!(caller, "handler must be a module name, got: #{Macro.to_string(handler)}")
    end
  end

  defp module_name?(value), do: is_atom(value) and value not in [nil, true, false]

  defp fail!(caller, description) do
    raise CompileError, file: caller.file, line: caller.line, description: description
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
