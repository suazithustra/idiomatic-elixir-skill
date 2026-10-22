defmodule TinyRouter do
  @moduledoc """
  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0` and
  > `match/1` in your module. Routes are checked when the module compiles.

  Declares routes in order and matches request paths against them. A segment
  that starts with `:` captures that part of the path into the params map.

  ## Examples

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{id: "42"}}
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route from `path` to the handler module `handler`.
  """
  defmacro get(path, handler) do
    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    public_routes = Enum.map(routes, fn {path, handler, _pattern} -> {path, handler} end)

    quote do
      @doc "Returns the declared routes as `{path, handler}` pairs, in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(public_routes))

      @doc "Matches a request path, returning its handler and the captured params."
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path), do: TinyRouter.Matcher.match(unquote(Macro.escape(routes)), path)
    end
  end

  @doc false
  @spec __define__(module(), term(), term()) :: :ok
  def __define__(module, path, handler) do
    validate_route!(module, path, handler)
    route = {path, handler, TinyRouter.Matcher.compile(path)}
    Module.put_attribute(module, :tiny_router_routes, route)
  end

  defguardp is_module_name(value) when is_atom(value) and value not in [nil, true, false]

  defp validate_route!(module, path, handler) do
    if not is_binary(path) do
      raise ArgumentError,
            "#{inspect(module)} declares get(#{inspect(path)}, ...), but the path must be a string"
    end

    if not is_module_name(handler) do
      raise ArgumentError,
            "#{inspect(module)} declares get(#{inspect(path)}, #{inspect(handler)}), " <>
              "but the handler must be a module name"
    end
  end
end

defmodule TinyRouter.Matcher do
  @moduledoc false

  @doc false
  @spec compile(String.t()) :: [String.t() | {:param, atom()}]
  def compile(path) do
    path
    |> segments()
    |> Enum.map(&compile_segment/1)
  end

  @doc false
  @spec match([{String.t(), module(), [String.t() | {:param, atom()}]}], String.t()) ::
          {:ok, module(), %{atom() => String.t()}} | :error
  def match(routes, path) do
    segments = segments(path)

    Enum.find_value(routes, :error, fn {_path, handler, pattern} ->
      case bind(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp segments(path), do: String.split(path, "/", trim: true)

  # The atom comes from the route declaration in source code, never from a
  # request, so it cannot grow the atom table at runtime.
  defp compile_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp compile_segment(literal), do: literal

  defp bind([], [], params), do: {:ok, params}

  defp bind([{:param, name} | pattern], [segment | segments], params) do
    bind(pattern, segments, Map.put(params, name, segment))
  end

  defp bind([literal | pattern], [literal | segments], params) do
    bind(pattern, segments, params)
  end

  defp bind(_pattern, _segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
