defmodule TinyRouter do
  @moduledoc """
  A tiny declarative router.

  Declare routes with `get/2` inside a module that does `use TinyRouter`.
  Each declared route becomes a `{path, handler}` pair, and the module gets
  `routes/0` and `match/1`.

  Paths must be string literals and handlers must be module names. Anything
  else raises a `CompileError` when the router module is compiled.
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  defmacro get(path, handler) do
    path = check_path!(path, __CALLER__)
    handler = check_handler!(handler, __CALLER__)

    quote do
      @tiny_router_routes {unquote(path), unquote(handler)}
    end
  end

  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(:tiny_router_routes)
      |> Enum.reverse()

    compiled = for {path, handler} <- routes, do: {split(path), handler}

    quote do
      def routes, do: unquote(Macro.escape(routes))

      def match(path) when is_binary(path) do
        TinyRouter.match_routes(unquote(Macro.escape(compiled)), path)
      end
    end
  end

  @doc false
  def match_routes(compiled, path) do
    request = split(path)

    Enum.find_value(compiled, :error, fn {pattern, handler} ->
      case bind(pattern, request, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  @doc false
  def split(path), do: String.split(path, "/", trim: true)

  defp bind([], [], params), do: {:ok, params}

  defp bind([":" <> name | pattern], [segment | request], params) do
    bind(pattern, request, Map.put(params, String.to_atom(name), segment))
  end

  defp bind([segment | pattern], [segment | request], params), do: bind(pattern, request, params)

  defp bind(_pattern, _request, _params), do: :error

  defp check_path!(path, _caller) when is_binary(path), do: path

  defp check_path!(other, caller) do
    compile_error!(
      caller,
      "route path must be a string literal, got: #{Macro.to_string(other)}"
    )
  end

  defp check_handler!(handler, caller) do
    case Macro.expand(handler, caller) do
      module when is_atom(module) ->
        if String.starts_with?(Atom.to_string(module), "Elixir.") do
          module
        else
          compile_error!(caller, "route handler must be a module name, got: #{inspect(module)}")
        end

      _other ->
        compile_error!(
          caller,
          "route handler must be a module name, got: #{Macro.to_string(handler)}"
        )
    end
  end

  defp compile_error!(caller, description) do
    raise CompileError, file: caller.file, line: caller.line, description: "TinyRouter: " <> description
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
