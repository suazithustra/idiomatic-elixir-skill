defmodule TinyRouter do
  @moduledoc """
  Declares routes in a module and matches request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0`
  > and `match/1` in your module.

  Path segments that start with `:` capture the matching request segment
  as a param.
  """

  @typep segment :: {:static, String.t()} | {:param, String.t()}

  @doc """
  Declares a route from `path` to `handler`.

  `path` must be a string and `handler` must be a module name. Any other
  value raises `CompileError` when the calling module compiles.

  ## Examples

      get "/users/:id", MyApp.UserHandler
  """
  defmacro get(path, handler) do
    location = [file: __CALLER__.file, line: __CALLER__.line]
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:call, 2}})

    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler), unquote(location))
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
    routes =
      env.module
      |> Module.get_attribute(:tiny_router_routes)
      |> Enum.reverse()

    compiled = Enum.map(routes, &compile_route/1)

    quote do
      @doc """
      Returns the declared `{path, handler}` pairs in declaration order.
      """
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc """
      Matches a request path against the declared routes.

      Returns `{:ok, handler, params}` for the first matching route, or `:error`.
      Params map each `:name` segment (without the colon) to the request's value,
      so `"/users/42"` matches `"/users/:id"` with params `%{"id" => "42"}`.
      """
      @spec match(String.t()) :: {:ok, module(), %{String.t() => String.t()}} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(path, unquote(Macro.escape(compiled)))
      end
    end
  end

  @doc false
  @spec __define__(module(), term(), term(), keyword()) :: :ok
  def __define__(module, path, handler, location) do
    check_path!(path, location)
    check_handler!(handler, location)
    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  @doc false
  @spec __match__(String.t(), [{[segment()], module()}]) ::
          {:ok, module(), %{String.t() => String.t()}} | :error
  def __match__(path, routes) do
    segments = split_path(path)
    Enum.find_value(routes, :error, &match_route(&1, segments))
  end

  defp compile_route({path, handler}) do
    segments =
      path
      |> split_path()
      |> Enum.map(&segment/1)

    {segments, handler}
  end

  defp match_route({pattern, handler}, segments) do
    case match_segments(pattern, segments, %{}) do
      {:ok, params} -> {:ok, handler, params}
      :error -> nil
    end
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:static, word} | pattern], [word | segments], params) do
    match_segments(pattern, segments, params)
  end

  defp match_segments([{:param, name} | pattern], [value | segments], params) do
    match_segments(pattern, segments, Map.put(params, name, value))
  end

  defp match_segments(_pattern, _segments, _params), do: :error

  defp split_path(path), do: String.split(path, "/", trim: true)

  defp segment(":" <> name), do: {:param, name}
  defp segment(word), do: {:static, word}

  defp check_path!(path, _location) when is_binary(path), do: :ok

  defp check_path!(path, location) do
    compile_error!(location, "route path must be a string, got: #{inspect(path)}")
  end

  defp check_handler!(handler, location) do
    if module_name?(handler) do
      :ok
    else
      compile_error!(location, "handler must be a module name, got: #{inspect(handler)}")
    end
  end

  defp module_name?(value) do
    is_atom(value) and String.starts_with?(Atom.to_string(value), "Elixir.")
  end

  defp compile_error!(location, description) do
    raise CompileError, file: location[:file], line: location[:line], description: description
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
