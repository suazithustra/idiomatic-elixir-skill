defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0` and
  > `match/1` in your module. Each route is checked as it is declared, so a
  > bad route fails the compilation of your module.

  A route path is a string. Each `:name` segment matches any one request
  segment and is returned under the atom key `name`. A handler is an atom
  naming the module that handles the route.

  ## Examples

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{id: "42"}}
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
  Declares a route from `path` to `handler`, in declaration order.
  """
  defmacro get(path, handler) do
    quote do
      TinyRouter.__put_route__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    pairs = Enum.map(routes, fn {path, handler, _segments} -> {path, handler} end)

    quote do
      @doc """
      Returns the declared `{path, handler}` pairs in declaration order.
      """
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(pairs))

      @doc """
      Returns `{:ok, handler, params}` for the first route that matches `path`,
      where `params` maps each `:name` segment to its value, or `:error` when no
      route matches.
      """
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(routes)), path)
      end
    end
  end

  @doc false
  @spec __put_route__(module(), term(), term()) :: :ok
  def __put_route__(module, path, handler) do
    if not is_binary(path), do: invalid!(module, "path must be a string", path)

    if not module_name?(handler),
      do: invalid!(module, "handler must be a module name", handler)

    Module.put_attribute(module, :tiny_router_routes, {path, handler, compile_path(path)})
  end

  @doc false
  @spec __match__([{String.t(), module(), [String.t() | atom()]}], String.t()) ::
          {:ok, module(), %{atom() => String.t()}} | :error
  def __match__(routes, path) do
    segments = split(path)
    Enum.find_value(routes, :error, &match_route(&1, segments))
  end

  defp invalid!(module, problem, value) do
    raise ArgumentError, "#{inspect(module)}: route #{problem}, got: #{inspect(value)}"
  end

  defp module_name?(handler), do: is_atom(handler) and handler not in [nil, true, false]

  defp compile_path(path), do: Enum.map(split(path), &compile_segment/1)

  # Atoms come from route declarations in source code, a fixed set, so
  # creating them here cannot be exhausted by request input.
  defp compile_segment(":" <> name), do: String.to_atom(name)
  defp compile_segment(segment), do: segment

  defp split(path), do: String.split(path, "/", trim: true)

  defp match_route({_path, handler, pattern}, segments) do
    case bind(pattern, segments, %{}) do
      {:ok, params} -> {:ok, handler, params}
      :error -> nil
    end
  end

  defp bind([], [], params), do: {:ok, params}

  defp bind([literal | pattern], [literal | segments], params) when is_binary(literal) do
    bind(pattern, segments, params)
  end

  defp bind([name | pattern], [value | segments], params) when is_atom(name) do
    bind(pattern, segments, Map.put(params, name, value))
  end

  defp bind(_pattern, _segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
