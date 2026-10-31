defmodule TinyRouter do
  @moduledoc """
  A small DSL (domain-specific language) for declaring routes.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports the `get/2` macro and defines
  > `routes/0` and `match/1` in your module.

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

  A path that is not a string, or a handler that is not a module name, raises
  an `ArgumentError` while the router module compiles.
  """

  @type segment :: String.t() | {:param, atom()}
  @type route :: {path :: String.t(), handler :: module(), segments :: [segment()]}

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route for `path`, served by `handler`.

  Segments that start with `:` capture the request segment under that name.
  """
  defmacro get(path, handler) do
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

    declared = for {path, handler, _segments} <- routes, do: {path, handler}

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(declared))

      @doc """
      Matches a request path against the declared routes.

      Returns `{:ok, handler, params}` for the first route that matches, or
      `:error`.
      """
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(routes)), path)
      end
    end
  end

  @doc false
  @spec __define__(module(), String.t(), module()) :: :ok
  def __define__(module, path, handler)
      when is_binary(path) and is_atom(handler) and handler not in [nil, true, false] do
    segments =
      path
      |> split()
      |> Enum.map(&parse_segment/1)

    Module.put_attribute(module, :tiny_router_routes, {path, handler, segments})
  end

  def __define__(_module, path, _handler) when not is_binary(path) do
    raise ArgumentError, "route path must be a string, got: #{inspect(path)}"
  end

  def __define__(_module, path, handler) do
    raise ArgumentError,
          "handler for #{inspect(path)} must be a module name, got: #{inspect(handler)}"
  end

  @doc false
  @spec __match__([route()], String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
  def __match__(routes, path) do
    request_segments = split(path)

    Enum.find_value(routes, :error, fn {_path, handler, segments} ->
      case match_segments(segments, request_segments, %{}) do
        {:ok, params} ->
          {:ok, handler, params}

        :error ->
          nil
      end
    end)
  end

  defp split(path), do: String.split(path, "/", trim: true)

  # Param names come from route declarations in the router's source, not from
  # request data, so creating these atoms is bounded.
  defp parse_segment(":" <> name) when name != "", do: {:param, String.to_atom(name)}
  defp parse_segment(literal), do: literal

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, name} | segments], [value | rest], params) do
    match_segments(segments, rest, Map.put(params, name, value))
  end

  defp match_segments([literal | segments], [literal | rest], params) when is_binary(literal) do
    match_segments(segments, rest, params)
  end

  defp match_segments(_segments, _request_segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
