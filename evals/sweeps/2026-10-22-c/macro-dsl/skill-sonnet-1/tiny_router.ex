defmodule TinyRouter do
  @moduledoc """
  A tiny compile-time router DSL.

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

  Segments starting with `:` capture the matching request segment.
  Raises `ArgumentError` at compile time if `path` is not a string starting
  with `/` or `handler` is not a module name.
  """
  defmacro get(path, handler) do
    # The handler is only stored, never called here, so expanding it as if it
    # were used inside a function avoids a compile-time dependency on it.
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

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc """
      Matches a request path.

      Returns `{:ok, handler, params}` or `:error`.
      """
      @spec match(String.t()) :: {:ok, module(), TinyRouter.params()} | :error
      def match(path) when is_binary(path), do: TinyRouter.__match__(routes(), path)
    end
  end

  @doc false
  @spec __define__(module(), term(), term()) :: :ok
  def __define__(module, path, handler) do
    validate_path!(path)
    validate_handler!(handler)

    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  @doc false
  @spec __match__([{String.t(), module()}], String.t()) :: {:ok, module(), params()} | :error
  def __match__(routes, path) do
    segments = split(path)

    Enum.find_value(routes, :error, fn {pattern, handler} ->
      case match_segments(split(pattern), segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([":" <> name | patterns], [value | values], params) do
    match_segments(patterns, values, Map.put(params, name, value))
  end

  defp match_segments([segment | patterns], [segment | values], params) do
    match_segments(patterns, values, params)
  end

  defp match_segments(_patterns, _values, _params), do: :error

  defp split(path), do: String.split(path, "/", trim: true)

  defp validate_path!("/" <> _rest), do: :ok

  defp validate_path!(path) when is_binary(path) do
    raise ArgumentError, "route path must start with \"/\", got: #{inspect(path)}"
  end

  defp validate_path!(path) do
    raise ArgumentError, "route path must be a string, got: #{inspect(path)}"
  end

  defp validate_handler!(handler) when is_atom(handler) and handler not in [nil, true, false],
    do: :ok

  defp validate_handler!(handler) do
    raise ArgumentError,
          "route handler must be a module name such as MyApp.PageHandler, got: #{inspect(handler)}"
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
