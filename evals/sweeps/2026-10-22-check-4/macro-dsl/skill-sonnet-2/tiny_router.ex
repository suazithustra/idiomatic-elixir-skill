defmodule TinyRouter do
  @moduledoc """
  A tiny compile-time route table.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0`
  > and `match/1` in your module.

  ## Examples

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.routes()
      #=> [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{"id" => "42"}}

      MyApp.Router.match("/nope")
      #=> :error
  """

  @type params :: %{optional(String.t()) => String.t()}

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route for `path` served by `handler`.

  `path` must be a string starting with `/`, where a segment such as `:id`
  captures that part of the request path. `handler` must be a module name.
  Raises `ArgumentError` when the enclosing module compiles if either is invalid.
  """
  defmacro get(path, handler) do
    # The handler is only stored, never called here, so expanding it as if it
    # were inside a function avoids a compile-time dependency on it.
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:match, 1}})

    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(:tiny_router_routes)
      |> Enum.reverse()

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc "Matches a request path against the declared routes."
      @spec match(String.t()) :: {:ok, module(), TinyRouter.params()} | :error
      def match(path) when is_binary(path), do: TinyRouter.__match__(routes(), path)
    end
  end

  @doc false
  @spec __define__(module(), term(), term()) :: :ok
  def __define__(module, path, handler) do
    if not (is_binary(path) and String.starts_with?(path, "/")) do
      raise ArgumentError,
            "route path must be a string starting with \"/\", got: #{inspect(path)}"
    end

    if not module_name?(handler) do
      raise ArgumentError,
            "route handler must be a module name, got: #{inspect(handler)}"
    end

    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  @doc false
  @spec __match__([{String.t(), module()}], String.t()) ::
          {:ok, module(), params()} | :error
  def __match__(routes, path) do
    segments = split(path)

    Enum.find_value(routes, :error, fn {pattern, handler} ->
      case match_segments(split(pattern), segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp module_name?(handler), do: is_atom(handler) and handler not in [nil, true, false]

  defp split(path), do: String.split(path, "/", trim: true)

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([":" <> name | patterns], [value | values], params) do
    match_segments(patterns, values, Map.put(params, name, value))
  end

  defp match_segments([segment | patterns], [segment | values], params) do
    match_segments(patterns, values, params)
  end

  defp match_segments(_patterns, _values, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
