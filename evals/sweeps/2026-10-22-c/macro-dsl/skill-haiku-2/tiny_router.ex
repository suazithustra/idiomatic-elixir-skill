defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0` and
  > `match/1` in your module.

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

      MyApp.Router.match("/missing/route")
      #=> :error

  The path must be a string and the handler must be a module name. Anything
  else raises `ArgumentError` when the router module compiles.
  """

  @doc false
  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route from `path` to `handler`.

  `path` must be a string, such as `"/users/:id"`, and `handler` a module name.
  """
  defmacro get(path, handler) do
    path = Macro.expand_literals(path, __CALLER__)
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:call, 2}})

    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_routes) |> Enum.reverse()
    matchers = Enum.map(routes, fn {path, handler} -> {__pattern__(path), handler} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs, in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc "Matches a request path against the declared routes, in declaration order."
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path), do: TinyRouter.__match__(unquote(Macro.escape(matchers)), path)
    end
  end

  @doc false
  @spec __define__(module(), term(), term()) :: :ok
  def __define__(module, path, handler) do
    if not is_binary(path) do
      raise ArgumentError,
            "#{inspect(module)}: get/2 expects a string path, got: #{inspect(path)}"
    end

    if not is_atom(handler) do
      raise ArgumentError,
            "#{inspect(module)}: get/2 expects a module name as handler, got: #{inspect(handler)}"
    end

    Module.put_attribute(module, :tiny_routes, {path, handler})
  end

  @doc false
  @spec __pattern__(String.t()) :: [{:literal, String.t()} | {:param, atom()}]
  def __pattern__(path) do
    for segment <- split(path) do
      case segment do
        ":" <> name -> {:param, String.to_atom(name)}
        literal -> {:literal, literal}
      end
    end
  end

  @doc false
  @spec __match__([{list(), module()}], term()) :: {:ok, module(), map()} | :error
  def __match__(matchers, path) when is_binary(path) do
    segments = split(path)

    Enum.find_value(matchers, :error, fn {pattern, handler} ->
      case match_pattern(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp split(path), do: String.split(path, "/", trim: true)

  defp match_pattern([], [], params), do: {:ok, params}

  defp match_pattern([{:literal, same} | pattern], [same | segments], params) do
    match_pattern(pattern, segments, params)
  end

  defp match_pattern([{:param, name} | pattern], [value | segments], params) do
    match_pattern(pattern, segments, Map.put(params, name, value))
  end

  defp match_pattern(_pattern, _segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
