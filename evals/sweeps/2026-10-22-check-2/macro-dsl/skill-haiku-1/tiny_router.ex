defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0`
  > and `match/1` in your module.

  ## Example

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{id: "42"}}

  A path must be a string literal and a handler must be a module name.
  Anything else fails when the module compiles.
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
  Declares a route for `path` that dispatches to `handler`.

  Routes are matched in declaration order. A segment that starts with `:`
  captures the matching part of the request path into `params`.
  """
  defmacro get(path, handler) do
    path = expand_path!(path, __CALLER__)
    handler = expand_handler!(handler, __CALLER__)
    segments = parse_path(path)

    quote do
      Module.put_attribute(
        __MODULE__,
        :tiny_router_routes,
        unquote(Macro.escape({path, handler, segments}))
      )
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    public_routes = Enum.map(routes, fn {path, handler, _segments} -> {path, handler} end)
    compiled = Enum.map(routes, fn {_path, handler, segments} -> {segments, handler} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(public_routes))

      @doc "Matches `path` against the declared routes, in declaration order."
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
      end
    end
  end

  @doc false
  @spec __match__([{[segment()], module()}], String.t()) ::
          {:ok, module(), %{atom() => String.t()}} | :error
  def __match__(routes, path) do
    segments = String.split(path, "/", trim: true)
    Enum.find_value(routes, :error, &try_route(&1, segments))
  end

  @typep segment :: {:literal, String.t()} | {:param, atom()}

  defp try_route({pattern, handler}, segments) do
    case bind(pattern, segments, %{}) do
      {:ok, params} -> {:ok, handler, params}
      :error -> nil
    end
  end

  defp bind([], [], params), do: {:ok, params}

  defp bind([{:literal, text} | pattern], [text | segments], params),
    do: bind(pattern, segments, params)

  defp bind([{:param, name} | pattern], [value | segments], params),
    do: bind(pattern, segments, Map.put(params, name, value))

  defp bind(_pattern, _segments, _params), do: :error

  defp expand_path!(path, env) do
    case Macro.expand(path, env) do
      expanded when is_binary(expanded) ->
        expanded

      _other ->
        fail!(env, "route path must be a string, got: #{Macro.to_string(path)}")
    end
  end

  defp expand_handler!(handler, env) do
    case Macro.expand(handler, env) do
      module when is_atom(module) ->
        module

      _other ->
        fail!(env, "route handler must be a module name, got: #{Macro.to_string(handler)}")
    end
  end

  defp parse_path(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&parse_segment/1)
  end

  defp parse_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp parse_segment(text), do: {:literal, text}

  defp fail!(env, description) do
    raise CompileError, file: env.file, line: env.line, description: description
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
