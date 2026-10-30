defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

  Path segments that start with `:` capture the matching request segment
  into `params`, under the atom after the colon. Paths must be string
  literals and handlers must be module names, such as `MyApp.PageHandler`.
  Any other declaration stops the compilation of the router module.
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
  Declares a route that sends requests for `path` to the module `handler`.
  """
  defmacro get(path, handler) do
    env = %{__CALLER__ | function: {:get, 2}}
    path = Macro.expand_literals(path, env)
    handler = Macro.expand_literals(handler, env)

    validate_path!(path, __CALLER__)
    validate_handler!(handler, __CALLER__)

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
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    compiled = Enum.map(routes, fn {path, handler} -> {parse_pattern(path), handler} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc "Returns the handler for `path` and its params, or `:error` when no route matches."
      @spec match(String.t()) :: {:ok, module(), map()} | :error
      def match(path), do: TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
    end
  end

  @doc false
  @spec __match__([{[String.t() | {:param, atom()}], module()}], String.t()) ::
          {:ok, module(), map()} | :error
  def __match__(routes, path) do
    segments = split_path(path)

    Enum.find_value(routes, :error, fn {pattern, handler} ->
      case bind(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp bind([], [], params), do: {:ok, params}

  defp bind([{:param, name} | pattern], [value | segments], params) do
    bind(pattern, segments, Map.put(params, name, value))
  end

  defp bind([literal | pattern], [literal | segments], params) do
    bind(pattern, segments, params)
  end

  defp bind(_pattern, _segments, _params), do: :error

  defp parse_pattern(path) do
    path
    |> split_path()
    |> Enum.map(fn
      ":" <> name -> {:param, String.to_atom(name)}
      segment -> segment
    end)
  end

  defp split_path(path), do: String.split(path, "/", trim: true)

  defp validate_path!(path, caller) do
    if not is_binary(path) do
      compile_error!(caller, "route path must be a string, got: #{Macro.to_string(path)}")
    end

    if ":" in split_path(path) do
      compile_error!(caller, "route #{inspect(path)} has a `:` segment with no name")
    end
  end

  defp validate_handler!(handler, caller) do
    if not module_name?(handler) do
      compile_error!(
        caller,
        "route handler must be a module name, such as MyApp.PageHandler, got: " <>
          Macro.to_string(handler)
      )
    end
  end

  defp module_name?(handler) do
    is_atom(handler) and String.starts_with?(Atom.to_string(handler), "Elixir.")
  end

  defp compile_error!(caller, description) do
    raise CompileError, file: caller.file, line: caller.line, description: description
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
