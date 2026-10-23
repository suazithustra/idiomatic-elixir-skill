defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0`
  > and `match/1` in your module. Invalid declarations raise when the
  > module compiles.

  ## Example

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.routes()
      #=> [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{id: "42"}}

      MyApp.Router.match("/missing")
      #=> :error
  """

  @doc """
  Declares a route from `path` to `handler`.

  `path` must be a string and `handler` a module name.
  """
  defmacro get(path, handler) do
    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc false
  @spec __define__(module(), term(), term()) :: :ok
  def __define__(module, path, handler) do
    if not is_binary(path) do
      raise ArgumentError, "route path must be a string, got: #{inspect(path)}"
    end

    if not is_atom(handler) or handler in [nil, true, false] do
      raise ArgumentError, "route handler must be a module name, got: #{inspect(handler)}"
    end

    Module.put_attribute(module, :tiny_routes, {path, handler})
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_routes) |> Enum.reverse()
    compiled = Enum.map(routes, fn {path, handler} -> {parse(path), handler} end)

    quote do
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path), do: TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
    end
  end

  @doc false
  @spec __match__([{list(), module()}], String.t()) ::
          {:ok, module(), %{atom() => String.t()}} | :error
  def __match__(compiled, path) when is_binary(path) do
    segments = split(path)

    Enum.find_value(compiled, :error, fn {pattern, handler} ->
      case bind(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp parse(path), do: path |> split() |> Enum.map(&parse_segment/1)

  # Patterns come from the developer's source at compile time, so creating
  # the parameter atoms here cannot be driven by request input.
  defp parse_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp parse_segment(segment), do: segment

  defp bind([], [], params), do: {:ok, params}

  defp bind([{:param, name} | pattern], [value | segments], params) do
    bind(pattern, segments, Map.put(params, name, value))
  end

  defp bind([segment | pattern], [segment | segments], params) do
    bind(pattern, segments, params)
  end

  defp bind(_pattern, _segments, _params), do: :error

  defp split(path), do: String.split(path, "/", trim: true)
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
