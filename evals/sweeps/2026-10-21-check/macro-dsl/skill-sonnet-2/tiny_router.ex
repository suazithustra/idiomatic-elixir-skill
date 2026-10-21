defmodule TinyRouter do
  @moduledoc """
  A small DSL (domain-specific language) for declaring routes.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines
  > `routes/0` and `match/1` in your module.

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
  `ArgumentError` when the router module compiles.
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
  Declares a route for `path`, served by `handler`.

  Segments that start with `:` are parameters, such as `:id` in `"/users/:id"`.
  """
  defmacro get(path, handler) do
    # The handler is only stored and called later, so it is expanded as if used
    # inside a function. That avoids a compile-time dependency on the handler.
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
      Matches a request path against the declared routes.

      Returns `{:ok, handler, params}` for the first route that fits, or `:error`.
      """
      @spec match(String.t()) :: {:ok, module(), %{optional(String.t()) => String.t()}} | :error
      def match(path) when is_binary(path), do: TinyRouter.__match__(routes(), path)
    end
  end

  @doc false
  @spec __define__(module(), term(), term()) :: :ok
  def __define__(module, path, handler) when is_binary(path) do
    if module_name?(handler) do
      validate_params!(path)
      Module.put_attribute(module, :tiny_router_routes, {path, handler})
    else
      raise ArgumentError,
            "TinyRouter: handler for #{inspect(path)} must be a module name, got: #{inspect(handler)}"
    end
  end

  def __define__(_module, path, _handler) do
    raise ArgumentError, "TinyRouter: route path must be a string, got: #{inspect(path)}"
  end

  @doc false
  @spec __match__([{String.t(), module()}], String.t()) ::
          {:ok, module(), %{optional(String.t()) => String.t()}} | :error
  def __match__(routes, request_path) do
    request_segments = segments(request_path)

    Enum.find_value(routes, :error, fn {pattern, handler} ->
      case match_segments(segments(pattern), request_segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp module_name?(handler), do: is_atom(handler) and handler not in [nil, true, false]

  defp validate_params!(path) do
    if ":" in segments(path) do
      raise ArgumentError,
            "TinyRouter: route #{inspect(path)} has a parameter segment with no name"
    end

    :ok
  end

  defp segments(path), do: String.split(path, "/", trim: true)

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([":" <> name | pattern], [value | request], params) do
    match_segments(pattern, request, Map.put(params, name, value))
  end

  defp match_segments([segment | pattern], [segment | request], params) do
    match_segments(pattern, request, params)
  end

  defp match_segments(_pattern, _request, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
