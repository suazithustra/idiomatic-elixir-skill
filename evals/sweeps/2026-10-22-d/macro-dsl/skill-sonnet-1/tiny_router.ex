defmodule TinyRouter do
  @moduledoc """
  A tiny compile-time router DSL.

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

      MyApp.Router.routes()
      #=> [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{"id" => "42"}}

  A path that is not a string, or a handler that is not a module name, raises
  an `ArgumentError` while the router module compiles.
  """

  defguardp is_valid_handler(handler) when is_atom(handler) and handler not in [nil, true, false]

  @doc false
  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)

      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route that sends `path` to `handler`.

  Segments starting with `:` capture the request segment under that name.
  """
  defmacro get(path, handler) do
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:match, 1}})

    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(:tiny_router_routes)
      |> Enum.reverse()

    declared = for {path, handler, _segments} <- routes, do: {path, handler}
    compiled = for {_path, handler, segments} <- routes, do: {segments, handler}

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(declared))

      @doc """
      Matches a request path.

      Returns `{:ok, handler, params}`, or `:error` when no route matches.
      """
      @spec match(String.t()) :: {:ok, module(), %{String.t() => String.t()}} | :error
      def match(request_path) when is_binary(request_path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled)), request_path)
      end
    end
  end

  @doc false
  @spec __define__(module(), String.t(), module()) :: :ok
  def __define__(module, path, handler) when is_binary(path) and is_valid_handler(handler) do
    segments = path |> split() |> Enum.map(&parse_segment/1)

    Module.put_attribute(module, :tiny_router_routes, {path, handler, segments})
  end

  def __define__(_module, path, _handler) when not is_binary(path) do
    raise ArgumentError, "route path must be a string, got: #{inspect(path)}"
  end

  def __define__(_module, _path, handler) do
    raise ArgumentError, "route handler must be a module name, got: #{inspect(handler)}"
  end

  @doc false
  @spec __match__([{[term()], module()}], String.t()) ::
          {:ok, module(), %{String.t() => String.t()}} | :error
  def __match__(routes, request_path) do
    request_segments = split(request_path)

    Enum.find_value(routes, :error, fn {segments, handler} ->
      case match_segments(segments, request_segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, name} | segments], [value | rest], params) do
    match_segments(segments, rest, Map.put(params, name, value))
  end

  defp match_segments([{:literal, segment} | segments], [segment | rest], params) do
    match_segments(segments, rest, params)
  end

  defp match_segments(_segments, _request_segments, _params), do: :error

  defp split(path), do: String.split(path, "/", trim: true)

  defp parse_segment(":" <> name), do: {:param, name}
  defp parse_segment(segment), do: {:literal, segment}
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
