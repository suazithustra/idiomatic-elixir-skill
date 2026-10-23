defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

  ## Usage

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

  `MyApp.Router.routes/0` returns the declared `{path, handler}` pairs in
  declaration order. `MyApp.Router.match/1` returns the first route that
  matches, as `{:ok, handler, params}`, or `:error`.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports the `get/2` macro, defines
  > `routes/0` and `match/1` in your module, and rejects invalid routes at
  > compile time.
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route from `path` to `handler`.

  `path` must be a string and `handler` must be a module name.
  """
  defmacro get(path, handler) do
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:call, 2}})

    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  @spec __define__(module(), term(), term()) :: :ok
  def __define__(module, path, handler) do
    validate_path!(path)
    validate_handler!(handler)
    Module.put_attribute(module, :tiny_routes, {path, handler})
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_routes) |> Enum.reverse()
    compiled = Enum.map(routes, fn {path, handler} -> {compile_segments(path), handler} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc "Returns `{:ok, handler, params}` for the first route that matches `path`, or `:error`."
      @spec match(String.t()) :: {:ok, module(), map()} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(path, unquote(Macro.escape(compiled)))
      end
    end
  end

  @doc false
  @spec __match__(String.t(), [{[segment], module()}]) :: {:ok, module(), map()} | :error
        when segment: {:static, String.t()} | {:param, atom()}
  def __match__(path, routes) do
    segments = String.split(path, "/", trim: true)

    Enum.find_value(routes, :error, fn {pattern, handler} ->
      case match_segments(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp validate_path!(path) do
    if not is_binary(path) do
      raise ArgumentError, "route path must be a string, got: #{inspect(path)}"
    end
  end

  defp validate_handler!(handler) do
    if not module_name?(handler) do
      raise ArgumentError, "route handler must be a module name, got: #{inspect(handler)}"
    end
  end

  defp module_name?(handler) do
    is_atom(handler) and String.starts_with?(Atom.to_string(handler), "Elixir.")
  end

  defp compile_segments(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(fn
      ":" <> name -> {:param, String.to_atom(name)}
      segment -> {:static, segment}
    end)
  end

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

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
