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

  A path must be a string literal and a handler must be a module name
  such as `MyApp.PageHandler`. Anything else fails when the router module
  compiles.

  A segment that starts with `:` captures the value at that position.
  Empty segments are ignored, so `"/users/42/"` matches the same route as
  `"/users/42"`.

  `use TinyRouter` defines `routes/0` and `match/1` in the calling module.
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

  Routes keep the order in which they are declared.
  """
  defmacro get(path, handler) do
    caller = __CALLER__
    expanded = Macro.expand_literals(handler, %{caller | function: {:call, 2}})

    if not is_binary(path) do
      compile_error!(caller, "route path must be a string, got: #{Macro.to_string(path)}")
    end

    if not (is_atom(expanded) and Macro.classify_atom(expanded) == :alias) do
      compile_error!(
        caller,
        "route handler must be a module name such as MyApp.PageHandler, got: " <>
          Macro.to_string(handler)
      )
    end

    quote do
      Module.put_attribute(__MODULE__, :tiny_router_routes, {unquote(path), unquote(expanded)})
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(:tiny_router_routes)
      |> Enum.reverse()

    compiled = Enum.map(routes, fn {path, handler} -> {route_pattern(path), handler} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc "Matches `path` against the declared routes."
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path), do: TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
    end
  end

  @doc false
  @spec __match__([{list(), module()}], String.t()) :: {:ok, module(), map()} | :error
  def __match__(routes, path) do
    segments = split(path)

    Enum.find_value(routes, :error, fn {pattern, handler} ->
      case bind(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp split(path), do: String.split(path, "/", trim: true)

  defp route_pattern(path) do
    path
    |> split()
    |> Enum.map(&segment/1)
  end

  # Route names come from the source code, never from a request, so
  # creating the atom here is safe.
  defp segment(":" <> name), do: {:param, String.to_atom(name)}
  defp segment(literal), do: {:literal, literal}

  defp bind([], [], params), do: {:ok, params}

  defp bind([{:literal, text} | pattern], [text | segments], params) do
    bind(pattern, segments, params)
  end

  defp bind([{:param, key} | pattern], [value | segments], params) do
    bind(pattern, segments, Map.put(params, key, value))
  end

  defp bind(_pattern, _segments, _params), do: :error

  defp compile_error!(caller, description) do
    raise CompileError, file: caller.file, line: caller.line, description: description
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
