defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and sets the module up to
  > collect routes. When the module compiles, it defines `routes/0` and
  > `match/1`. Each `get/2` call must pass a string path and a module name.

  ## Example

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{id: "42"}}
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
    quote do
      TinyRouter.__define__(__ENV__, unquote(path), unquote(handler))
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    compiled = Enum.map(routes, fn {path, handler} -> {segments(path), handler} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc "Returns `{:ok, handler, params}` for the first route matching `path`, or `:error`."
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
      end
    end
  end

  @doc false
  @spec __define__(Macro.Env.t(), term(), term()) :: :ok
  def __define__(%Macro.Env{} = env, path, handler) do
    if not is_binary(path), do: fail(env, "expected a string path, got: #{inspect(path)}")

    if not module_name?(handler),
      do: fail(env, "expected a module name as handler, got: #{inspect(handler)}")

    Module.put_attribute(env.module, :tiny_router_routes, {path, handler})
  end

  @doc false
  @spec __match__([{list(), module()}], String.t()) :: {:ok, module(), map()} | :error
  def __match__(routes, path) do
    segments = String.split(path, "/", trim: true)

    Enum.find_value(routes, :error, fn {pattern, handler} ->
      case match_segments(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp fail(env, message) do
    raise CompileError, file: env.file, line: env.line, description: "TinyRouter: " <> message
  end

  defp module_name?(handler) when is_atom(handler) do
    String.starts_with?(Atom.to_string(handler), "Elixir.")
  end

  defp module_name?(_handler), do: false

  defp segments(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&segment/1)
  end

  # Route text comes from the source file, so the atoms created here are bounded.
  defp segment(":" <> name), do: {:param, String.to_atom(name)}
  defp segment(name), do: {:static, name}

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:static, name} | pattern], [name | path], params) do
    match_segments(pattern, path, params)
  end

  defp match_segments([{:param, key} | pattern], [value | path], params) do
    match_segments(pattern, path, Map.put(params, key, value))
  end

  defp match_segments(_pattern, _path, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
