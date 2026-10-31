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

      MyApp.Router.match("/nowhere")
      #=> :error

  A path that is not a string, or a handler that is not a module name, raises
  `ArgumentError` when the router module compiles.
  """

  @routes_attribute :tiny_router_routes

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, unquote(@routes_attribute), accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route for `path`, served by `handler`.

  Segments that start with `:` are parameters, returned by `match/1` under the
  atom of the same name.
  """
  defmacro get(path, handler) do
    # The handler is only stored, so expand it as if used inside a function:
    # that avoids a compile-time dependency on the handler module.
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:call, 2}})

    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(@routes_attribute)
      |> Enum.reverse()

    patterns = Enum.map(routes, fn {path, handler} -> {parse_path(path), handler} end)

    quote do
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @spec match(String.t()) :: {:ok, module(), %{optional(atom()) => String.t()}} | :error
      def match(path), do: TinyRouter.__match__(unquote(Macro.escape(patterns)), path)
    end
  end

  @doc false
  @spec __define__(module(), String.t(), module()) :: :ok
  def __define__(module, path, handler) when is_binary(path) do
    if not module_name?(handler) do
      raise ArgumentError,
            "handler for #{inspect(path)} must be a module name, got: #{inspect(handler)}"
    end

    Module.put_attribute(module, @routes_attribute, {path, handler})
  end

  def __define__(_module, path, _handler) do
    raise ArgumentError, "route path must be a string, got: #{inspect(path)}"
  end

  @doc false
  @spec __match__([{list(), module()}], String.t()) ::
          {:ok, module(), %{optional(atom()) => String.t()}} | :error
  def __match__(patterns, path) when is_binary(path) do
    segments = split_path(path)

    Enum.find_value(patterns, :error, fn {pattern, handler} ->
      case match_segments(pattern, segments, %{}) do
        {:ok, params} ->
          {:ok, handler, params}

        :error ->
          nil
      end
    end)
  end

  defp module_name?(handler), do: is_atom(handler) and Macro.classify_atom(handler) == :alias

  defp parse_path(path) do
    path
    |> split_path()
    |> Enum.map(&parse_segment/1)
  end

  defp parse_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp parse_segment(segment), do: segment

  defp split_path(path), do: String.split(path, "/", trim: true)

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, name} | pattern], [value | segments], params) do
    match_segments(pattern, segments, Map.put(params, name, value))
  end

  defp match_segments([segment | pattern], [segment | segments], params)
       when is_binary(segment) do
    match_segments(pattern, segments, params)
  end

  defp match_segments(_pattern, _segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
