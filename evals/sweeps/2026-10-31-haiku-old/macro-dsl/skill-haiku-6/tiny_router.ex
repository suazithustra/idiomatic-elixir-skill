defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports the `get/2` macro. When the module
  > compiles, it also defines `routes/0` and `match/1`.

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

  @typedoc false
  @type segment :: {:literal, String.t()} | {:param, atom()}

  @doc """
  Declares a route for `path`, handled by `handler`.

  `path` must be a string and `handler` must be a module name. A segment that
  starts with `:` captures the request's value for that segment into the params.
  """
  defmacro get(path, handler) do
    quote do
      TinyRouter.__put_route__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_routes) |> Enum.reverse()
    compiled = Enum.map(routes, fn {path, handler} -> {parse_pattern(path), handler} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc "Returns `{:ok, handler, params}` for the first matching route, or `:error`."
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path) when is_binary(path) do
        TinyRouter.Matcher.match(unquote(Macro.escape(compiled)), path)
      end
    end
  end

  @doc false
  def __put_route__(module, path, handler) do
    validate_path!(path)
    validate_handler!(path, handler)
    Module.put_attribute(module, :tiny_routes, {path, handler})
  end

  defp validate_path!(path) do
    if not is_binary(path) do
      raise ArgumentError, "route path must be a string, got: #{inspect(path)}"
    end
  end

  defp validate_handler!(path, handler) do
    if not module_name?(handler) do
      message = "handler for #{inspect(path)} must be a module name, got: #{inspect(handler)}"
      raise ArgumentError, message
    end
  end

  defp module_name?(handler), do: is_atom(handler) and handler not in [nil, true, false]

  defp parse_pattern(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(fn
      # Names come from the router source at compile time, so creating atoms here is safe.
      ":" <> name -> {:param, String.to_atom(name)}
      segment -> {:literal, segment}
    end)
  end
end

defmodule TinyRouter.Matcher do
  @moduledoc false

  @doc false
  @spec match([{[TinyRouter.segment()], module()}], String.t()) ::
          {:ok, module(), map()} | :error
  def match(routes, path) do
    segments = String.split(path, "/", trim: true)

    Enum.find_value(routes, :error, fn {pattern, handler} ->
      case bind(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp bind([], [], params), do: {:ok, params}

  defp bind([{:literal, same} | pattern], [same | segments], params) do
    bind(pattern, segments, params)
  end

  defp bind([{:param, name} | pattern], [value | segments], params) do
    bind(pattern, segments, Map.put(params, name, value))
  end

  defp bind(_pattern, _segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
