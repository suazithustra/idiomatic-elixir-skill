defmodule TinyRouter do
  @moduledoc """
  A small routing DSL (domain-specific language).

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

  A path that is not a string, or a handler that is not a module name, raises
  an `ArgumentError` when the router module compiles.
  """

  @typedoc "A compiled path: literal segments and `{:param, name}` segments."
  @type segment :: String.t() | {:param, String.t()}

  @type route :: {String.t(), module(), [segment()]}

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)

      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route for `path`, handled by the module `handler`.

  Segments that start with `:` capture the matching part of the request path.
  """
  defmacro get(path, handler) do
    # The handler is only stored and returned, so expanding it as if it were
    # used inside a function avoids a compile-time dependency on it.
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:routes, 0}})

    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = Enum.reverse(Module.get_attribute(env.module, :tiny_router_routes))
    pairs = Enum.map(routes, fn {path, handler, _segments} -> {path, handler} end)

    quote do
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(pairs))

      @spec match(String.t()) :: {:ok, module(), %{String.t() => String.t()}} | :error
      def match(request_path) when is_binary(request_path) do
        TinyRouter.__match__(unquote(Macro.escape(routes)), request_path)
      end
    end
  end

  @doc false
  @spec __define__(module(), term(), term()) :: :ok
  def __define__(module, path, handler) when is_binary(path) do
    if not module_name?(handler) do
      raise ArgumentError,
            "TinyRouter: the handler for #{inspect(path)} must be a module name, " <>
              "got: #{inspect(handler)}"
    end

    Module.put_attribute(module, :tiny_router_routes, {path, handler, compile_path(path)})
  end

  def __define__(_module, path, _handler) do
    raise ArgumentError, "TinyRouter: the path must be a string, got: #{inspect(path)}"
  end

  @doc false
  @spec __match__([route()], String.t()) ::
          {:ok, module(), %{String.t() => String.t()}} | :error
  def __match__(routes, request_path) do
    request_segments = split(request_path)

    Enum.find_value(routes, :error, fn {_path, handler, segments} ->
      case match_segments(segments, request_segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp module_name?(handler) do
    is_atom(handler) and match?("Elixir." <> _name, Atom.to_string(handler))
  end

  defp compile_path(path) do
    for segment <- split(path) do
      case segment do
        ":" <> name -> {:param, name}
        literal -> literal
      end
    end
  end

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
