defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and adds a
  > `@before_compile` hook that defines `routes/0` and `match/1` in
  > your module.

  Path segments are separated by `/`. A segment that starts with `:`
  captures the request segment under that name, so `"/users/:id"`
  matches `"/users/42"` with the params `%{id: "42"}`.
  """

  @doc """
  Declares a route from `path` to `handler`.

  `path` must be a string and `handler` a module name. Both are checked
  when the module compiles.
  """
  defmacro get(path, handler) do
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:call, 2}})

    quote location: :keep do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    compiled = Enum.reverse(Module.get_attribute(env.module, :tiny_router_routes))
    pairs = for {path, handler, _segments} <- compiled, do: {path, handler}

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(pairs))

      @doc "Returns `{:ok, handler, params}` for the first route matching `path`, or `:error`."
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
      end
    end
  end

  @doc false
  @spec __define__(module(), term(), term()) :: :ok
  def __define__(module, path, handler) do
    if not is_binary(path) do
      raise ArgumentError, "route path must be a string, got: #{inspect(path)}"
    end

    if not (is_atom(handler) and Macro.classify_atom(handler) == :alias) do
      raise ArgumentError, "handler must be a module name, got: #{inspect(handler)}"
    end

    segments = path |> split() |> Enum.map(&segment/1)
    Module.put_attribute(module, :tiny_router_routes, {path, handler, segments})
    :ok
  end

  @doc false
  @spec __match__([{String.t(), module(), [segment()]}], String.t()) ::
          {:ok, module(), %{atom() => String.t()}} | :error
  def __match__(routes, path) do
    request = split(path)

    Enum.find_value(routes, :error, fn {_path, handler, segments} ->
      case bind(segments, request, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  @typep segment :: {:static, String.t()} | {:param, atom()}

  defp split(path), do: String.split(path, "/", trim: true)

  defp segment(":" <> name), do: {:param, String.to_atom(name)}
  defp segment(name), do: {:static, name}

  defp bind([], [], params), do: {:ok, params}

  defp bind([{:static, name} | segments], [name | request], params) do
    bind(segments, request, params)
  end

  defp bind([{:param, name} | segments], [value | request], params) do
    bind(segments, request, Map.put(params, name, value))
  end

  defp bind(_segments, _request, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
