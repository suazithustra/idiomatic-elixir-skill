defmodule TinyRouter do
  @moduledoc """
  A small DSL (domain-specific language) for declaring routes.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0`
  > and `match/1` in your module.

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

      MyApp.Router.match("/nope")
      #=> :error

  A path or handler of the wrong type raises `ArgumentError` while the
  router module compiles.
  """

  @typep segment :: String.t() | {:param, atom()}

  @doc false
  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route for `path` that is served by `handler`.

  `path` must be a string; segments that start with `:` capture the
  request segment under that name. `handler` must be a module name.
  """
  defmacro get(path, handler) do
    # The handler is only stored, never called here, so expand the alias
    # as if it were inside a function to avoid a compile-time dependency.
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:match, 1}})

    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  @spec __define__(module(), term(), term()) :: :ok
  def __define__(module, path, handler) do
    validate_path!(path)
    validate_handler!(handler)

    Module.put_attribute(module, :tiny_router_routes, {path, handler, parse_path(path)})
  end

  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(:tiny_router_routes)
      |> Enum.reverse()

    declared = Enum.map(routes, fn {path, handler, _segments} -> {path, handler} end)
    compiled = Enum.map(routes, fn {_path, handler, segments} -> {handler, segments} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(declared))

      @doc """
      Finds the handler for a request path.

      Returns `{:ok, handler, params}`, or `:error` when no route matches.
      """
      @spec match(String.t()) :: {:ok, module(), %{optional(atom()) => String.t()}} | :error
      def match(request_path) when is_binary(request_path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled)), request_path)
      end
    end
  end

  @doc false
  @spec __match__([{module(), [segment()]}], String.t()) ::
          {:ok, module(), %{optional(atom()) => String.t()}} | :error
  def __match__(routes, request_path) do
    request_segments = split_path(request_path)

    Enum.find_value(routes, :error, fn {handler, segments} ->
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

  defp match_segments([segment | segments], [segment | rest], params) when is_binary(segment) do
    match_segments(segments, rest, params)
  end

  defp match_segments(_segments, _request_segments, _params), do: :error

  defp validate_path!(path) when is_binary(path), do: :ok

  defp validate_path!(path) do
    raise ArgumentError, "TinyRouter: route path must be a string, got: #{inspect(path)}"
  end

  defp validate_handler!(handler) when is_atom(handler) and handler not in [nil, true, false],
    do: :ok

  defp validate_handler!(handler) do
    raise ArgumentError,
          "TinyRouter: route handler must be a module name, got: #{inspect(handler)}"
  end

  defp parse_path(path) do
    path
    |> split_path()
    |> Enum.map(&parse_segment/1)
  end

  defp split_path(path), do: String.split(path, "/", trim: true)

  defp parse_segment(":"), do: raise(ArgumentError, "TinyRouter: parameter name is empty")

  # The name comes from the router's source code, not from a request, so
  # the set of atoms created here is fixed by the program text.
  defp parse_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp parse_segment(literal), do: literal
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
