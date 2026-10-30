defmodule TinyRouter do
  @moduledoc """
  Declares routes as `{path, handler}` pairs and matches request paths against them.

  ## Usage

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

  `use TinyRouter` imports `get/2` and defines `routes/0` and `match/1`
  in the calling module. An invalid route fails when the module compiles.
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
  Declares a route from `path` to `handler`.

  `path` must be a string and `handler` must be a module name, such as
  `MyApp.UserHandler`. Routes keep their declaration order.
  """
  defmacro get(path, handler) do
    quote do
      TinyRouter.__put_route__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  @spec __put_route__(module(), term(), term()) :: :ok
  def __put_route__(module, path, handler) do
    if not is_binary(path) do
      raise ArgumentError,
            "route path must be a string, got: #{inspect(path)} in #{inspect(module)}"
    end

    if not module_name?(handler) do
      raise ArgumentError,
            "route handler must be a module name, got: #{inspect(handler)} " <>
              "for path #{inspect(path)} in #{inspect(module)}"
    end

    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  defp module_name?(handler) do
    is_atom(handler) and String.starts_with?(Atom.to_string(handler), "Elixir.")
  end

  @doc false
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

      @doc """
      Returns `{:ok, handler, params}` for the first route that matches `path`,
      or `:error`. Params are keyed by the atom names of `:name` segments.
      """
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path), do: TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
    end
  end

  @doc false
  @spec __match__([{[tuple()], module()}], String.t()) ::
          {:ok, module(), %{atom() => String.t()}} | :error
  def __match__(routes, path) when is_binary(path) do
    request = split(path)

    Enum.find_value(routes, :error, fn {pattern, handler} ->
      case match_segments(pattern, request, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:static, text} | pattern], [text | request], params) do
    match_segments(pattern, request, params)
  end

  defp match_segments([{:param, name} | pattern], [value | request], params) do
    match_segments(pattern, request, Map.put(params, name, value))
  end

  defp match_segments(_pattern, _request, _params), do: :error

  defp segments(path) do
    path
    |> split()
    |> Enum.map(&segment/1)
  end

  defp segment(":" <> name), do: {:param, String.to_atom(name)}
  defp segment(literal), do: {:static, literal}

  defp split(path), do: String.split(path, "/", trim: true)
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
