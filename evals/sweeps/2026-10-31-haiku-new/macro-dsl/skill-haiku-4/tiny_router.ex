defmodule TinyRouter do
  @moduledoc """
  Declares request paths and the handler module for each one.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0` and
  > `match/1` in your module.

  ## Example

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{id: "42"}}
  """

  @doc """
  Declares a route from `path` to `handler`.

  `path` must be a string and `handler` a module name. Both are checked when
  the module that calls `get/2` compiles.
  """
  defmacro get(path, handler) do
    location = {__CALLER__.file, __CALLER__.line}

    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler), unquote(location))
    end
  end

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(:tiny_router_routes)
      |> Enum.reverse()

    compiled = Enum.map(routes, fn {path, handler} -> {segments(path), handler} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc "Returns the handler for `path` and its `:name` segment values, or `:error`."
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
      end
    end
  end

  @doc false
  @spec __define__(module(), term(), term(), {String.t(), pos_integer()}) :: :ok
  def __define__(module, path, handler, {file, line}) do
    where = "#{file}:#{line}"

    if not is_binary(path) do
      raise ArgumentError, "#{where}: route path must be a string, got: #{inspect(path)}"
    end

    if not is_atom(handler) or handler in [nil, true, false] do
      raise ArgumentError, "#{where}: handler must be a module name, got: #{inspect(handler)}"
    end

    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  @doc false
  def __match__(compiled, path) do
    segments = split_path(path)

    Enum.find_value(compiled, :error, fn {pattern, handler} ->
      case match_segments(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp segments(path) do
    path
    |> split_path()
    |> Enum.map(fn
      ":" <> name -> {:param, String.to_atom(name)}
      segment -> {:static, segment}
    end)
  end

  defp split_path(path), do: String.split(path, "/", trim: true)

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:static, same} | pattern], [same | segments], params) do
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
