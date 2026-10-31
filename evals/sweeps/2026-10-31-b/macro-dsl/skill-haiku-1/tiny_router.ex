defmodule TinyRouter do
  @moduledoc """
  Declares request routes in a module and matches request paths against them.

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{id: "42"}}

  `use TinyRouter` imports `get/2`. Each call records a `{path, handler}` pair in
  declaration order. The path must be a string and the handler must be a module
  name; anything else raises `ArgumentError` when the router module compiles.

  The router module gets two functions:

    * `routes/0` returns the `{path, handler}` pairs in declaration order.
    * `match/1` returns `{:ok, handler, params}` for the first route whose path
      matches, or `:error`. A segment written `:name` captures the request segment
      into `params` under the atom key `name`.
  """

  @typep segment :: {:static, String.t()} | {:param, atom()}

  @doc false
  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc false
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
      |> Module.get_attribute(:routes)
      |> Enum.reverse()

    compiled = for {path, handler} <- routes, do: {compile_path(path), handler}

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc "Matches a request path against the declared routes."
      @spec match(String.t()) :: {:ok, module(), map()} | :error
      def match(path), do: TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
    end
  end

  @doc false
  @spec __define__(module(), term(), term()) :: :ok
  def __define__(module, path, handler) do
    if not is_binary(path) do
      raise ArgumentError, "route path must be a string, got: #{inspect(path)}"
    end

    if not module_name?(handler) do
      raise ArgumentError, "route handler must be a module name, got: #{inspect(handler)}"
    end

    Module.put_attribute(module, :routes, {path, handler})
  end

  @doc false
  @spec __match__([{[segment()], module()}], String.t()) :: {:ok, module(), map()} | :error
  def __match__(routes, path) when is_binary(path) do
    segments = split_path(path)

    Enum.find_value(routes, :error, fn {route, handler} ->
      case match_segments(route, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp module_name?(value), do: is_atom(value) and Macro.classify_atom(value) == :alias

  defp compile_path(path) do
    for segment <- split_path(path), do: compile_segment(segment)
  end

  defp compile_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp compile_segment(segment), do: {:static, segment}

  defp split_path(path), do: String.split(path, "/", trim: true)

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:static, segment} | route], [segment | request], params) do
    match_segments(route, request, params)
  end

  defp match_segments([{:param, key} | route], [value | request], params) do
    match_segments(route, request, Map.put(params, key, value))
  end

  defp match_segments(_route, _request, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
