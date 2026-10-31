defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

  Use it in a module and declare each route with `get/2`:

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.routes()
      #=> [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{id: "42"}}

  The path must be a string literal and the handler must be a module name
  written as an alias. Both are checked when the module compiles.
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)

      @before_compile TinyRouter
    end
  end

  @doc """
  Declares that requests for `path` are handled by `handler`.
  """
  defmacro get(path, handler) do
    path = validate_path!(path)
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:call, 2}})
    handler = validate_handler!(handler)

    quote do
      TinyRouter.__put_route__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  @spec __put_route__(module(), String.t(), module()) :: :ok
  def __put_route__(module, path, handler) do
    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  @doc false
  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(:tiny_router_routes)
      |> Enum.reverse()

    quote do
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path) when is_binary(path), do: TinyRouter.__match__(routes(), path)
    end
  end

  @doc false
  @spec __match__([{String.t(), module()}], String.t()) ::
          {:ok, module(), %{atom() => String.t()}} | :error
  def __match__(routes, path) do
    segments = split(path)

    Enum.find_value(routes, :error, fn {route, handler} ->
      case bind(split(route), segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp validate_path!(path) when is_binary(path), do: path

  defp validate_path!(path) do
    raise ArgumentError,
          "route path must be a string literal, got: #{Macro.to_string(path)}"
  end

  defp validate_handler!(handler) do
    if is_atom(handler) and Macro.classify_atom(handler) == :alias do
      handler
    else
      raise ArgumentError,
            "handler must be a module name such as MyApp.PageHandler, " <>
              "got: #{Macro.to_string(handler)}"
    end
  end

  defp split(path), do: String.split(path, "/", trim: true)

  # Parameter names come from the declared routes, never from request input,
  # so the number of atoms created here is bounded by the source code.
  defp bind([], [], params), do: {:ok, params}

  defp bind([":" <> name | route], [segment | path], params) do
    bind(route, path, Map.put(params, String.to_atom(name), segment))
  end

  defp bind([part | route], [part | path], params), do: bind(route, path, params)
  defp bind(_route, _path, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
