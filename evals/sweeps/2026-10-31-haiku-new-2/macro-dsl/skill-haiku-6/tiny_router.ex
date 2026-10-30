defmodule TinyRouter do
  @moduledoc """
  Declares request routes in a module and matches request paths against them.

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.routes()
      #=> [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{id: "42"}}

  `use TinyRouter` imports `get/2` and defines `routes/0` and `match/1` in the
  module. Paths must be strings and handlers must be module names. Both are
  checked when the router module compiles.
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
    location = {__CALLER__.file, __CALLER__.line}

    quote do
      TinyRouter.__put_route__(__MODULE__, unquote(path), unquote(handler), unquote(location))
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    declared =
      env.module
      |> Module.get_attribute(:tiny_router_routes)
      |> Enum.reverse()

    compiled = Enum.map(declared, fn {path, handler} -> {split_pattern(path), handler} end)

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
  @spec __put_route__(module(), term(), term(), {String.t(), pos_integer()}) :: :ok
  def __put_route__(module, path, handler, location) do
    if not is_binary(path) do
      raise_at(location, "route path must be a string, got: #{inspect(path)}")
    end

    if not is_atom(handler) do
      raise_at(location, "route handler must be a module name, got: #{inspect(handler)}")
    end

    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  @doc false
  @spec __match__([{[String.t() | {:param, atom()}], module()}], String.t()) ::
          {:ok, module(), map()} | :error
  def __match__(routes, path) do
    segments = split_path(path)

    Enum.find_value(routes, :error, &match_route(&1, segments))
  end

  defp match_route({pattern, handler}, segments) do
    case match_segments(pattern, segments, %{}) do
      {:ok, params} -> {:ok, handler, params}
      :error -> nil
    end
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, name} | pattern], [value | segments], params) do
    match_segments(pattern, segments, Map.put(params, name, value))
  end

  defp match_segments([literal | pattern], [literal | segments], params) do
    match_segments(pattern, segments, params)
  end

  defp match_segments(_pattern, _segments, _params), do: :error

  defp split_pattern(path) do
    Enum.map(split_path(path), &segment_pattern/1)
  end

  # Route paths are written in source code, so the atoms are bounded by the code.
  defp segment_pattern(":" <> name), do: {:param, String.to_atom(name)}
  defp segment_pattern(literal), do: literal

  defp split_path(path), do: String.split(path, "/", trim: true)

  defp raise_at({file, line}, description) do
    raise CompileError, file: file, line: line, description: description
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
