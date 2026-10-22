defmodule TinyRouter do
  @moduledoc """
  A tiny compile-time route table.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `TinyRouter.get/2` and defines
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
      #=> {:ok, MyApp.UserHandler, %{"id" => "42"}}

      MyApp.Router.match("/nope")
      #=> :error

  Param names are kept as strings, so request paths never create atoms.
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
  Declares a route for `path` handled by the module `handler`.

  Raises `ArgumentError` at compile time if `path` is not a string starting
  with `"/"` or `handler` is not a module name.
  """
  defmacro get(path, handler) do
    # The handler is only stored, never called here, so expand it as if it
    # were used inside a function to avoid a compile-time dependency.
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:routes, 0}})

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
      Matches a request path, returning the handler and the `:name` segments.
      """
      @spec match(String.t()) :: {:ok, module(), %{String.t() => String.t()}} | :error
      def match(path) when is_binary(path), do: TinyRouter.__match__(routes(), path)
    end
  end

  @doc false
  @spec __define__(module(), String.t(), module()) :: :ok
  def __define__(module, "/" <> _ = path, handler)
      when is_atom(handler) and handler not in [nil, true, false] do
    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  def __define__(_module, path, _handler) when not is_binary(path) do
    raise ArgumentError, "route path must be a string, got: #{inspect(path)}"
  end

  def __define__(_module, path, handler)
      when not is_atom(handler) or handler in [nil, true, false] do
    raise ArgumentError,
          "route handler for #{inspect(path)} must be a module name, got: #{inspect(handler)}"
  end

  def __define__(_module, path, _handler) do
    raise ArgumentError, ~s(route path must start with "/", got: #{inspect(path)})
  end

  @doc false
  @spec __match__([{String.t(), module()}], String.t()) ::
          {:ok, module(), %{String.t() => String.t()}} | :error
  def __match__(routes, request_path) do
    request_segments = split(request_path)

    Enum.find_value(routes, :error, fn {pattern, handler} ->
      case match_segments(split(pattern), request_segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

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

defmodule MyApp.PageHandler do
  @moduledoc false
end

defmodule MyApp.UserHandler do
  @moduledoc false
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
