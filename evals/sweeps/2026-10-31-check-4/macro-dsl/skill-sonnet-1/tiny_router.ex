defmodule TinyRouter do
  @moduledoc """
  A small routing DSL (domain-specific language) that maps request paths to handler modules.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports the `get/2` macro and defines
  > `routes/0` and `match/1` in your module.

  ## Example

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.routes()
      #=> [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{id: "42"}}

      MyApp.Router.match("/missing")
      #=> :error

  A path or handler of the wrong type raises `ArgumentError` when the router
  module compiles. A handler must be written as a module name such as
  `MyApp.PageHandler`.
  """

  @typep segment :: String.t() | {:param, atom()}
  @typep route :: {String.t(), module(), [segment()]}

  @doc false
  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)

      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route for `path`, handled by the module `handler`.

  Segments that start with `:` capture the request segment under that name.
  """
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
      |> Module.get_attribute(:tiny_router_routes)
      |> Enum.reverse()

    declared = Enum.map(routes, fn {path, handler, _segments} -> {path, handler} end)

    quote do
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(declared))

      @spec match(String.t()) :: {:ok, module(), %{optional(atom()) => String.t()}} | :error
      def match(path), do: TinyRouter.match(unquote(Macro.escape(routes)), path)
    end
  end

  @doc false
  @spec __define__(module(), term(), term()) :: :ok
  def __define__(module, path, handler) when is_binary(path) do
    if not (is_atom(handler) and Macro.classify_atom(handler) == :alias) do
      raise ArgumentError,
            "route #{inspect(path)}: handler must be a module name such as MyApp.PageHandler, " <>
              "got: #{inspect(handler)}"
    end

    Module.put_attribute(module, :tiny_router_routes, {path, handler, parse_path(path)})
  end

  def __define__(_module, path, _handler) do
    raise ArgumentError, "route path must be a string, got: #{inspect(path)}"
  end

  @doc false
  @spec match([route()], String.t()) :: {:ok, module(), map()} | :error
  def match(routes, path) when is_binary(path) do
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

  defp parse_path(path) do
    Enum.map(split(path), &parse_segment/1)
  end

  # Parameter names come from the developer's own route declarations at
  # compile time, so the set of atoms is bounded by the source code.
  defp parse_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp parse_segment(literal), do: literal

  defp split(path), do: String.split(path, "/", trim: true)

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
