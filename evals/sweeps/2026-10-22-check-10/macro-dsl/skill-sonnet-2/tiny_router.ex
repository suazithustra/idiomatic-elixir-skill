defmodule TinyRouter do
  @moduledoc """
  A tiny compile-time router DSL.

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
      #=> {:ok, MyApp.UserHandler, %{"id" => "42"}}

      MyApp.Router.match("/nope")
      #=> :error

  Params are keyed by strings, so matching never creates atoms.
  """

  @routes_attribute :tiny_router_routes

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, unquote(@routes_attribute), accumulate: true)

      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route from `path` to `handler`.

  Raises `ArgumentError` at compile time if `path` is not a string or
  `handler` is not a module name.
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
      |> Module.get_attribute(@routes_attribute)
      |> Enum.reverse()

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc """
      Matches a request path against the declared routes.

      Returns `{:ok, handler, params}` or `:error`.
      """
      @spec match(String.t()) :: {:ok, module(), %{optional(String.t()) => String.t()}} | :error
      def match(request_path) when is_binary(request_path) do
        TinyRouter.__match__(routes(), request_path)
      end
    end
  end

  @doc false
  @spec __define__(module(), term(), term()) :: :ok
  def __define__(module, path, handler) when is_binary(path) do
    if not module_name?(handler) do
      raise ArgumentError,
            "route handler must be a module name such as MyApp.PageHandler, " <>
              "got: #{inspect(handler)} for path #{inspect(path)}"
    end

    Module.put_attribute(module, @routes_attribute, {path, handler})
  end

  def __define__(_module, path, _handler) do
    raise ArgumentError, "route path must be a string, got: #{inspect(path)}"
  end

  @doc false
  @spec __match__([{String.t(), module()}], String.t()) ::
          {:ok, module(), %{optional(String.t()) => String.t()}} | :error
  def __match__(routes, request_path) do
    request_segments = split(request_path)

    Enum.find_value(routes, :error, fn {path, handler} ->
      case match_segments(split(path), request_segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp module_name?(handler) when is_atom(handler) do
    String.starts_with?(Atom.to_string(handler), "Elixir.")
  end

  defp module_name?(_handler), do: false

  defp split(path), do: String.split(path, "/", trim: true)

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([":" <> name | route_rest], [value | request_rest], params) do
    match_segments(route_rest, request_rest, Map.put(params, name, value))
  end

  defp match_segments([segment | route_rest], [segment | request_rest], params) do
    match_segments(route_rest, request_rest, params)
  end

  defp match_segments(_route_segments, _request_segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
