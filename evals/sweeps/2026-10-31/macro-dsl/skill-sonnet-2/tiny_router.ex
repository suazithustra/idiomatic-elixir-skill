defmodule TinyRouter do
  @moduledoc """
  A small DSL (domain-specific language) for declaring routes.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports the `get/2` macro and defines
  > `routes/0` and `match/1` in your module.

  ## Examples

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

  @type segment :: String.t() | {:param, atom()}
  @type route :: {String.t(), module(), [segment()]}

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)

      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route for `path` that is served by `handler`.

  Segments that start with `:` capture the matching part of a request path.
  Raises `ArgumentError` at compile time when `path` is not a string or
  `handler` is not a module name.
  """
  defmacro get(path, handler) do
    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  @spec __define__(module(), term(), term()) :: :ok
  def __define__(module, path, handler) when is_binary(path) do
    validate_handler!(handler)
    Module.put_attribute(module, :tiny_router_routes, {path, handler, segments(path)})
  end

  def __define__(_module, path, _handler) do
    raise ArgumentError, "route path must be a string, got: #{inspect(path)}"
  end

  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(:tiny_router_routes)
      |> Enum.reverse()

    declared = Enum.map(routes, fn {path, handler, _segments} -> {path, handler} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(declared))

      @doc """
      Finds the handler for a request path.

      Returns `{:ok, handler, params}` or `:error`.
      """
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path), do: TinyRouter.match(unquote(Macro.escape(routes)), path)
    end
  end

  @doc false
  @spec match([route()], String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
  def match(routes, path) when is_binary(path) do
    request = split(path)

    Enum.find_value(routes, :error, fn {_pattern, handler, segments} ->
      case match_segments(segments, request, %{}) do
        {:ok, params} ->
          {:ok, handler, params}

        :error ->
          nil
      end
    end)
  end

  defp validate_handler!(handler) when is_atom(handler) and handler not in [nil, true, false] do
    :ok
  end

  defp validate_handler!(handler) do
    raise ArgumentError, "route handler must be a module name, got: #{inspect(handler)}"
  end

  defp segments(path) do
    Enum.map(split(path), &segment/1)
  end

  defp segment(":" <> name), do: {:param, String.to_atom(name)}
  defp segment(literal), do: literal

  defp split(path), do: String.split(path, "/", trim: true)

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, name} | rest], [value | values], params) do
    match_segments(rest, values, Map.put(params, name, value))
  end

  defp match_segments([literal | rest], [literal | values], params) do
    match_segments(rest, values, params)
  end

  defp match_segments(_segments, _request, _params), do: :error
end

defmodule MyApp.PageHandler do
  @moduledoc false
end

defmodule MyApp.UserHandler do
  @moduledoc false
end

defmodule MyApp.Router do
  @moduledoc false

  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
