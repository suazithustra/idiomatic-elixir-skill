defmodule TinyRouter do
  @moduledoc """
  Declares request paths and their handler modules in a router module.

  > #### `use TinyRouter` {: .info}
  >
  > Imports `get/2` and defines `routes/0` and `match/1` in the calling module.

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{id: "42"}}

  Routes are checked when the router module compiles. A path that is not a
  string, or a handler that is not a module name, stops the compile with an
  `ArgumentError`.
  """

  @typedoc "One part of a route path: a fixed word or a named parameter."
  @type segment :: {:literal, String.t()} | {:param, atom()}

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route from `path` to `handler`.
  """
  defmacro get(path, handler) do
    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  @spec __define__(module(), term(), term()) :: :ok
  def __define__(module, path, handler) do
    if not is_binary(path) do
      raise ArgumentError,
            "#{inspect(module)}: route path must be a string, got: #{inspect(path)}"
    end

    if not module_name?(handler) do
      raise ArgumentError,
            "#{inspect(module)}: route handler must be a module name, got: #{inspect(handler)}"
    end

    Module.put_attribute(module, :tiny_router_routes, {path, handler, parse_path(path)})
  end

  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(:tiny_router_routes)
      |> Enum.reverse()

    declared = Enum.map(routes, fn {path, handler, _segments} -> {path, handler} end)
    compiled = Enum.map(routes, fn {_path, handler, segments} -> {segments, handler} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(declared))

      @doc "Returns `{:ok, handler, params}` for the first route that matches `path`, or `:error`."
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
      end
    end
  end

  @doc false
  @spec __match__([{[segment()], module()}], String.t()) ::
          {:ok, module(), %{atom() => String.t()}} | :error
  def __match__(routes, path) do
    segments = split_path(path)

    Enum.find_value(routes, :error, fn {pattern, handler} ->
      case match_segments(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp module_name?(handler), do: is_atom(handler) and handler not in [nil, true, false]

  defp parse_path(path) do
    path
    |> split_path()
    |> Enum.map(&parse_segment/1)
  end

  # Parameter names come from the router source, not from requests, so the
  # atoms they create are bounded by the code.
  defp parse_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp parse_segment(word), do: {:literal, word}

  defp split_path(path), do: String.split(path, "/", trim: true)

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:literal, word} | pattern], [word | segments], params) do
    match_segments(pattern, segments, params)
  end

  defp match_segments([{:param, name} | pattern], [value | segments], params) do
    match_segments(pattern, segments, Map.put(params, name, value))
  end

  defp match_segments(_pattern, _segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
