defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

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
  Declares a route. `path` must be a string and `handler` a module name.
  """
  defmacro get(path, handler) do
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:call, 2}})

    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  @spec __define__(module(), term(), term()) :: :ok
  def __define__(module, path, handler) do
    if not is_binary(path) do
      message = "#{inspect(module)}: route path must be a string, got: #{inspect(path)}"
      raise ArgumentError, message
    end

    if not module_name?(handler) do
      message =
        "#{inspect(module)}: route handler must be a module name, got: #{inspect(handler)}"

      raise ArgumentError, message
    end

    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  defp module_name?(handler), do: is_atom(handler) and handler not in [nil, true, false]

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    compiled = Enum.map(routes, fn {path, handler} -> {compile_path(path), handler} end)

    quote do
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(path, unquote(Macro.escape(compiled)))
      end
    end
  end

  @doc false
  @spec __match__(String.t(), [{[String.t() | {:param, atom()}], module()}]) ::
          {:ok, module(), %{atom() => String.t()}} | :error
  def __match__(path, routes) do
    segments = String.split(path, "/", trim: true)

    Enum.find_value(routes, :error, &match_route(&1, segments))
  end

  defp compile_path(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&compile_segment/1)
  end

  defp compile_segment(":" <> name) when name != "", do: {:param, String.to_atom(name)}
  defp compile_segment(literal), do: literal

  defp match_route({pattern, handler}, segments) do
    case bind(pattern, segments, []) do
      {:ok, params} -> {:ok, handler, Map.new(params)}
      :error -> nil
    end
  end

  defp bind([], [], params), do: {:ok, params}

  defp bind([{:param, name} | pattern], [value | segments], params) do
    bind(pattern, segments, [{name, value} | params])
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
