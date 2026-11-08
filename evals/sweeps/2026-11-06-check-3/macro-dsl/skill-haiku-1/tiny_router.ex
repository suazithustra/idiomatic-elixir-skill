defmodule TinyRouter do
  @moduledoc """
  Declares request routes in a module and matches request paths against them.

  Use it in your own module and declare routes with `get/2`:

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

  > #### `use TinyRouter` {: .info}
  >
  > Imports `get/2` into your module and adds `routes/0` and `match/1`
  > to it. Both functions are generated when your module compiles.

  A path must be a string. A handler must be a module name written as
  an alias, such as `MyApp.PageHandler`. A bad value stops the
  compilation of your module with an `ArgumentError`.

  A segment that starts with `:` captures the matching request segment.
  The captured values are returned as a map keyed by atoms, so
  `"/users/:id"` matches `"/users/42"` with params `%{id: "42"}`.
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route from `path` to `handler`.

  `path` must be a string and `handler` must be a module name.
  """
  defmacro get(path, handler) do
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:call, 2}})

    quote location: :keep do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  @spec __define__(module(), term(), term()) :: :ok
  def __define__(module, path, handler) do
    if not is_binary(path) do
      raise ArgumentError,
            "route path must be a string, got: #{inspect(path)}"
    end

    if not (is_atom(handler) and Macro.classify_atom(handler) == :alias) do
      raise ArgumentError,
            "route handler must be a module name such as MyApp.PageHandler, " <>
              "got: #{inspect(handler)}"
    end

    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  @doc false
  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(:tiny_router_routes)
      |> Enum.reverse()

    compiled = Enum.map(routes, fn {path, handler} -> {compile_path(path), handler} end)

    quote location: :keep do
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @spec match(String.t()) :: {:ok, module(), map()} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
      end
    end
  end

  @doc false
  @spec __match__([{[{:literal, String.t()} | {:param, atom()}], module()}], String.t()) ::
          {:ok, module(), map()} | :error
  def __match__(routes, path) do
    segments = String.split(path, "/", trim: true)

    Enum.find_value(routes, :error, fn {pattern, handler} ->
      case match_segments(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp compile_path(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&compile_segment/1)
  end

  defp compile_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp compile_segment(literal), do: {:literal, literal}

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, name} | pattern], [value | segments], params) do
    match_segments(pattern, segments, Map.put(params, name, value))
  end

  defp match_segments([{:literal, same} | pattern], [same | segments], params) do
    match_segments(pattern, segments, params)
  end

  defp match_segments(_pattern, _segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
