defmodule TinyRouter do
  @moduledoc """
  A small router DSL. Modules that `use TinyRouter` declare routes with `get/2`.
  Each route is checked when the module compiles.

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.routes()
      #=> [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{"id" => "42"}}
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route. `path` must be a string literal and `handler` must be a module name.
  """
  defmacro get(path, handler) do
    path = validate_path!(path, __CALLER__)
    handler = validate_handler!(handler, __CALLER__)

    quote do
      @tiny_router_routes {unquote(path), unquote(handler)}
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    declared =
      env.module
      |> Module.get_attribute(:tiny_router_routes)
      |> Enum.reverse()

    compiled = Enum.map(declared, fn {path, handler} -> {compile_pattern(path), handler} end)

    quote do
      def routes, do: unquote(Macro.escape(declared))

      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
      end
    end
  end

  @doc false
  def __match__(compiled, path) do
    segments = split(path)

    Enum.find_value(compiled, :error, fn {pattern, handler} ->
      case bind(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp validate_path!(path, _caller) when is_binary(path), do: path

  defp validate_path!(other, caller) do
    raise_compile_error!(
      caller,
      "route path must be a string literal, got: #{Macro.to_string(other)}"
    )
  end

  defp validate_handler!(handler, caller) do
    expanded = Macro.expand(handler, caller)

    if is_atom(expanded) and expanded not in [nil, true, false] do
      expanded
    else
      raise_compile_error!(
        caller,
        "route handler must be a module name, got: #{Macro.to_string(handler)}"
      )
    end
  end

  defp raise_compile_error!(caller, message) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "TinyRouter: " <> message
  end

  defp split(path), do: String.split(path, "/", trim: true)

  defp compile_pattern(path) do
    path
    |> split()
    |> Enum.map(fn
      ":" <> name -> {:param, name}
      segment -> {:literal, segment}
    end)
  end

  defp bind([], [], params), do: {:ok, params}

  defp bind([{:literal, segment} | pattern], [segment | segments], params) do
    bind(pattern, segments, params)
  end

  defp bind([{:param, name} | pattern], [value | segments], params) do
    bind(pattern, segments, Map.put(params, name, value))
  end

  defp bind(_pattern, _segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
