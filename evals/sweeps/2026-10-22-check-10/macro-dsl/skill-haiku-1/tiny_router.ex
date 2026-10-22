defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0` and
  > `match/1` in your module. Invalid routes fail when the module compiles.

  Routes are tried in declaration order, and the first match wins. A segment
  that starts with `:` captures the matching request segment under that name.

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.match("/users/42")
      # => {:ok, MyApp.UserHandler, %{id: "42"}}
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)

      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route from `path` to the `handler` module.
  """
  defmacro get(path, handler) do
    quote do
      TinyRouter.__put_route__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    compiled = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()

    quote do
      @spec routes() :: [{String.t(), module()}]
      def routes, do: TinyRouter.__routes__(unquote(Macro.escape(compiled)))

      @spec match(String.t()) :: {:ok, module(), map()} | :error
      def match(path), do: TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
    end
  end

  @doc false
  @spec __put_route__(module(), term(), term()) :: :ok
  def __put_route__(module, path, handler) do
    if not is_binary(path) do
      raise ArgumentError,
            "#{inspect(module)}: route path must be a string, got: #{inspect(path)}"
    end

    if not module_name?(handler) do
      raise ArgumentError,
            "#{inspect(module)}: route #{inspect(path)} must name a handler module, " <>
              "got: #{inspect(handler)}"
    end

    Module.put_attribute(module, :tiny_router_routes, {path, handler, segments(path)})
  end

  @doc false
  @spec __routes__([{String.t(), module(), list()}]) :: [{String.t(), module()}]
  def __routes__(compiled) do
    Enum.map(compiled, fn {path, handler, _segments} -> {path, handler} end)
  end

  @doc false
  @spec __match__([{String.t(), module(), list()}], String.t()) ::
          {:ok, module(), map()} | :error
  def __match__(compiled, path) when is_binary(path) do
    segments = split(path)

    Enum.find_value(compiled, :error, fn {_path, handler, pattern} ->
      case match_segments(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp module_name?(handler), do: is_atom(handler) and handler not in [nil, true, false]

  defp segments(path), do: Enum.map(split(path), &segment/1)

  defp split(path), do: String.split(path, "/", trim: true)

  defp segment(":" <> name), do: {:param, String.to_atom(name)}
  defp segment(name), do: {:static, name}

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:static, name} | pattern], [name | segments], params) do
    match_segments(pattern, segments, params)
  end

  defp match_segments([{:param, key} | pattern], [value | segments], params) do
    match_segments(pattern, segments, Map.put(params, key, value))
  end

  defp match_segments(_pattern, _segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
