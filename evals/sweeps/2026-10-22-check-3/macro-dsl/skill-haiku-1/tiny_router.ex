defmodule TinyRouter do
  @moduledoc """
  A small router that maps request paths to handler modules.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports the `get/2` macro, collects the
  > routes you declare, and defines `routes/0` and `match/1` in your module.

  Paths are split on `/`. A segment that starts with `:` captures the
  request segment under that name. Captured values are strings, so
  `get "/users/:id", Handler` matched against `"/users/42"` gives
  `%{"id" => "42"}`.
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
    # The handler is only stored and returned at runtime, so expand it as if
    # it were used inside a function. This keeps it out of compile-time
    # dependencies.
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:call, 2}})

    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc """
      Finds the handler for `path`. Returns `{:ok, handler, params}` or `:error`.
      """
      @spec match(String.t()) :: {:ok, module(), %{String.t() => String.t()}} | :error
      def match(path), do: TinyRouter.__match__(routes(), path)
    end
  end

  @doc false
  @spec __define__(module(), term(), term()) :: :ok
  def __define__(module, path, handler) do
    if not is_binary(path) do
      raise ArgumentError,
            "route path in #{inspect(module)} must be a string, got: #{inspect(path)}"
    end

    if not module_name?(handler) do
      raise ArgumentError,
            "route handler in #{inspect(module)} must be a module name, " <>
              "got: #{inspect(handler)}"
    end

    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  @doc false
  @spec __match__([{String.t(), module()}], String.t()) ::
          {:ok, module(), %{String.t() => String.t()}} | :error
  def __match__(routes, path) when is_binary(path) do
    segments = split(path)

    Enum.find_value(routes, :error, fn {route, handler} ->
      case match_segments(split(route), segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp module_name?(handler) do
    is_atom(handler) and String.starts_with?(Atom.to_string(handler), "Elixir.")
  end

  defp split(path), do: String.split(path, "/", trim: true)

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([":" <> name | route_rest], [segment | path_rest], params) do
    match_segments(route_rest, path_rest, Map.put(params, name, segment))
  end

  defp match_segments([same | route_rest], [same | path_rest], params) do
    match_segments(route_rest, path_rest, params)
  end

  defp match_segments(_route, _path, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
