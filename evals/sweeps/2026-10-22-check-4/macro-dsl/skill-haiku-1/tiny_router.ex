defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0` and
  > `match/1` in your module when the module compiles.

  ## Example

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{id: "42"}}

  Routes are tried in declaration order, and the first match wins.
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
  Declares a route from `path` to `handler`.

  Raises `ArgumentError` when the module compiles if `path` is not a string or
  `handler` is not a module name.
  """
  defmacro get(path, handler) do
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:call, 2}})

    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()

    quote do
      @doc """
      Returns the declared `{path, handler}` pairs in declaration order.
      """
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc """
      Returns `{:ok, handler, params}` for the first route that matches `path`,
      or `:error`. `params` maps each `:name` segment to its value.
      """
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path) when is_binary(path), do: TinyRouter.__match__(routes(), path)
    end
  end

  @doc false
  @spec __define__(module(), term(), term()) :: :ok
  def __define__(module, path, handler) do
    if not is_binary(path) do
      raise ArgumentError,
            "route path must be a string, got: #{inspect(path)} (in #{inspect(module)})"
    end

    if not module_name?(handler) do
      raise ArgumentError,
            "route handler for #{inspect(path)} must be a module name, " <>
              "got: #{inspect(handler)} (in #{inspect(module)})"
    end

    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  @doc false
  @spec __match__([{String.t(), module()}], String.t()) :: {:ok, module(), map()} | :error
  def __match__(routes, path) do
    segments = split(path)

    Enum.find_value(routes, :error, fn {route_path, handler} ->
      case bind(split(route_path), segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp module_name?(value), do: is_atom(value) and value not in [nil, true, false]

  defp split(path), do: String.split(path, "/", trim: true)

  # Route patterns come from source code, not from requests, so the number of
  # atoms created here is bounded by the declared routes.
  defp bind([], [], params), do: {:ok, params}

  defp bind([":" <> name | route_rest], [segment | path_rest], params) do
    bind(route_rest, path_rest, Map.put(params, String.to_atom(name), segment))
  end

  defp bind([literal | route_rest], [literal | path_rest], params) do
    bind(route_rest, path_rest, params)
  end

  defp bind(_route_segments, _path_segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
