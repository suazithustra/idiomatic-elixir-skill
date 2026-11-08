defmodule TinyRouter do
  @moduledoc """
  A small DSL (domain-specific language) for declaring routes.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0`
  > and `match/1` in your module.

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

      MyApp.Router.match("/nope")
      #=> :error

  A path that is not a string, or a handler that is not a module name,
  raises `ArgumentError` when the router module compiles.
  """

  @typep segment :: String.t() | {:param, atom()}
  @typep route :: {String.t(), module(), [segment()]}

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)

      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route for `path`, handled by the module `handler`.

  Segments that start with `:` match any value and are returned in the params.
  """
  defmacro get(path, handler) do
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:call, 2}})

    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(:tiny_router_routes)
      |> Enum.reverse()

    pairs = Enum.map(routes, fn {path, handler, _segments} -> {path, handler} end)

    quote do
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(pairs))

      @spec match(String.t()) :: {:ok, module(), %{optional(atom()) => String.t()}} | :error
      def match(request_path) do
        TinyRouter.match(unquote(Macro.escape(routes)), request_path)
      end
    end
  end

  @doc false
  @spec __define__(module(), String.t(), module()) :: :ok
  def __define__(module, path, handler) when is_binary(path) do
    if not module_name?(handler) do
      raise ArgumentError,
            "TinyRouter: the handler for #{inspect(path)} must be a module name, " <>
              "got: #{inspect(handler)}"
    end

    Module.put_attribute(module, :tiny_router_routes, {path, handler, segments(path)})
  end

  def __define__(_module, path, _handler) do
    raise ArgumentError, "TinyRouter: a route path must be a string, got: #{inspect(path)}"
  end

  @doc false
  @spec match([route()], String.t()) :: {:ok, module(), map()} | :error
  def match(routes, request_path) when is_binary(request_path) do
    request_segments = split(request_path)

    Enum.find_value(routes, :error, fn {_path, handler, segments} ->
      case match_segments(segments, request_segments, %{}) do
        {:ok, params} ->
          {:ok, handler, params}

        :error ->
          nil
      end
    end)
  end

  defp module_name?(handler), do: is_atom(handler) and handler not in [nil, true, false]

  defp segments(path) do
    path
    |> split()
    |> Enum.map(&segment/1)
  end

  defp split(path), do: String.split(path, "/", trim: true)

  defp segment(":" <> name) when name != "", do: {:param, String.to_atom(name)}
  defp segment(literal), do: literal

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, name} | segments], [value | values], params) do
    match_segments(segments, values, Map.put(params, name, value))
  end

  defp match_segments([literal | segments], [literal | values], params) do
    match_segments(segments, values, params)
  end

  defp match_segments(_segments, _values, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
