defmodule TinyRouter do
  @moduledoc """
  Declares routes at compile time and matches request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2`, defines `routes/0` and
  > `match/1` in your module, and collects the declared routes with a
  > `@before_compile` hook.
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route from `path` to `handler`, a module name.

  Invalid arguments raise `ArgumentError` when the module compiles.
  """
  defmacro get(path, handler) do
    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  @spec __define__(module(), term(), term()) :: :ok
  def __define__(module, path, handler) do
    if not is_binary(path) do
      raise ArgumentError,
            "#{inspect(module)}: route path must be a string, got: #{inspect(path)}"
    end

    if not is_atom(handler) or handler in [nil, true, false] do
      raise ArgumentError,
            "#{inspect(module)}: route handler must be a module name, got: #{inspect(handler)}"
    end

    Module.put_attribute(module, :tiny_routes, {path, handler})
  end

  defmacro __before_compile__(env) do
    pairs = env.module |> Module.get_attribute(:tiny_routes) |> Enum.reverse()
    compiled = Enum.map(pairs, fn {path, handler} -> {__parse__(path), handler} end)

    quote do
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(pairs))

      @spec match(String.t()) :: {:ok, module(), map()} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
      end
    end
  end

  @doc false
  @spec __parse__(String.t()) :: [{:static, String.t()} | {:param, atom()}]
  def __parse__(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&parse_segment/1)
  end

  defp parse_segment(":" <> name), do: {:param, String.to_atom(name)}
  defp parse_segment(segment), do: {:static, segment}

  @doc false
  @spec __match__([{[{:static, String.t()} | {:param, atom()}], module()}], String.t()) ::
          {:ok, module(), map()} | :error
  def __match__(routes, path) do
    segments = String.split(path, "/", trim: true)

    Enum.find_value(routes, :error, fn {pattern, handler} ->
      case match_segments(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:static, text} | pattern], [text | segments], params) do
    match_segments(pattern, segments, params)
  end

  defp match_segments([{:param, key} | pattern], [value | segments], params) do
    match_segments(pattern, segments, Map.put(params, key, value))
  end

  defp match_segments(_pattern, _segments, _params), do: :error
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
