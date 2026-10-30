defmodule TinyRouter do
  @moduledoc """
  A small DSL (domain-specific language) for declaring routes.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0`
  > and `match/1` in your module.

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

  A path that is not a string, or a handler that is not a module name, raises
  `ArgumentError` when the router module compiles.
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)

      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route for `path`, served by the module `handler`.

  Segments that start with `:` match any one segment and are returned by
  `match/1` under that name as an atom key.
  """
  defmacro get(path, handler) do
    # The handler is only stored, never called here, so expanding it as if it
    # sat inside a function keeps the router from depending on it at compile time.
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:call, 2}})

    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(:tiny_router_routes)
      |> Enum.reverse()

    declared = Enum.map(routes, fn {path, handler, _segments} -> {path, handler} end)

    quote do
      @doc """
      Returns the declared `{path, handler}` pairs in declaration order.
      """
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(declared))

      @doc """
      Finds the first route that matches `path`.

      Returns `{:ok, handler, params}` or `:error`.
      """
      @spec match(String.t()) :: {:ok, module(), %{optional(atom()) => String.t()}} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(routes)), path)
      end
    end
  end

  @doc false
  @spec __define__(module(), String.t(), module()) :: :ok
  def __define__(module, path, handler)
      when is_binary(path) and is_atom(handler) and handler not in [nil, true, false] do
    Module.put_attribute(module, :tiny_router_routes, {path, handler, parse_segments(path)})
  end

  def __define__(module, path, _handler) when not is_binary(path) do
    raise ArgumentError,
          "#{inspect(module)}: route path must be a string, got: #{inspect(path)}"
  end

  def __define__(module, path, handler) do
    raise ArgumentError,
          "#{inspect(module)}: handler for #{inspect(path)} must be a module name, " <>
            "got: #{inspect(handler)}"
  end

  @doc false
  @spec __match__([{String.t(), module(), list()}], String.t()) ::
          {:ok, module(), map()} | :error
  def __match__(routes, path) do
    request_segments = String.split(path, "/", trim: true)
    find_route(routes, request_segments)
  end

  defp parse_segments(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&parse_segment/1)
  end

  # Param names come from the router's own source, not from requests, so
  # creating the atoms here is bounded.
  defp parse_segment(":"), do: raise(ArgumentError, "route param needs a name, got \":\"")
  defp parse_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp parse_segment(literal), do: literal

  defp find_route([], _request_segments), do: :error

  defp find_route([{_path, handler, segments} | rest], request_segments) do
    case match_segments(segments, request_segments, %{}) do
      {:ok, params} ->
        {:ok, handler, params}

      :error ->
        find_route(rest, request_segments)
    end
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, name} | segments], [value | values], params) do
    match_segments(segments, values, Map.put(params, name, value))
  end

  defp match_segments([literal | segments], [literal | values], params) when is_binary(literal) do
    match_segments(segments, values, params)
  end

  defp match_segments(_segments, _values, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
