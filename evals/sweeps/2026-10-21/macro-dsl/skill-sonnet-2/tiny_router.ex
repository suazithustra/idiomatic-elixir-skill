defmodule TinyRouter do
  @moduledoc """
  A small DSL (domain-specific language) for declaring routes.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0` and
  > `match/1` in your module.

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.routes()
      #=> [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{"id" => "42"}}

  A path must be a string literal and a handler must be a module name. Anything
  else raises a `CompileError` when the router is compiled.
  """

  @routes_attribute :tiny_router_routes

  @doc false
  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, unquote(@routes_attribute), accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route for `path`, served by `handler`.

  Segments starting with `:` match any single path segment and are returned
  in the params map under their name, as strings.
  """
  defmacro get(path, handler) do
    # Expanding without a function in the environment keeps the handler a
    # runtime dependency, so changing a handler does not recompile the router.
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:routes, 0}})

    validate_path!(path, __CALLER__)
    validate_handler!(handler, __CALLER__)

    quote do
      @tiny_router_routes {unquote(path), unquote(handler)}
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(@routes_attribute) |> Enum.reverse()

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(routes)

      @doc """
      Finds the handler for a request path.

      Returns `{:ok, handler, params}` or `:error`.
      """
      @spec match(String.t()) :: {:ok, module(), %{String.t() => String.t()}} | :error
      def match(path) when is_binary(path), do: TinyRouter.match(routes(), path)
    end
  end

  @doc false
  @spec match([{String.t(), module()}], String.t()) ::
          {:ok, module(), %{String.t() => String.t()}} | :error
  def match(routes, path) when is_list(routes) and is_binary(path) do
    segments = split(path)

    Enum.find_value(routes, :error, fn {route_path, handler} ->
      case match_segments(split(route_path), segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp split(path), do: String.split(path, "/", trim: true)

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([":" <> name | route_rest], [value | rest], params) do
    match_segments(route_rest, rest, Map.put(params, name, value))
  end

  defp match_segments([segment | route_rest], [segment | rest], params) do
    match_segments(route_rest, rest, params)
  end

  defp match_segments(_route_segments, _segments, _params), do: :error

  defp validate_path!(path, _caller) when is_binary(path), do: :ok

  defp validate_path!(path, caller) do
    raise_compile_error!(
      caller,
      "route path must be a string literal, got: #{Macro.to_string(path)}"
    )
  end

  defp validate_handler!(handler, caller) do
    if module_name?(handler) do
      :ok
    else
      raise_compile_error!(
        caller,
        "route handler must be a module name such as MyApp.PageHandler, " <>
          "got: #{Macro.to_string(handler)}"
      )
    end
  end

  defp module_name?(handler) when handler in [nil, true, false], do: false

  defp module_name?(handler) when is_atom(handler),
    do: match?("Elixir." <> _, Atom.to_string(handler))

  defp module_name?(_handler), do: false

  defp raise_compile_error!(caller, description) do
    raise CompileError, file: caller.file, line: caller.line, description: description
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
