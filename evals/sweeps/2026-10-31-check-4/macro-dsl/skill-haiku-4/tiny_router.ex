defmodule TinyRouter do
  @moduledoc """
  Declares path routes in a module and matches request paths to them.

  ## Example

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.routes()
      #=> [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{id: "42"}}

      MyApp.Router.match("/missing")
      #=> :error

  ## Compile-time checks

  The path of `get/2` must be a string literal, and the handler must be a
  module name. Otherwise the caller fails to compile.
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route from `path` to `handler`.
  """
  defmacro get(path, handler) do
    validate_path!(__CALLER__, path)

    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:call, 2}})
    validate_handler!(__CALLER__, handler)

    quote do
      @tiny_router_routes {unquote(path), unquote(handler)}
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(:tiny_router_routes)
      |> Enum.reverse()

    compiled = Enum.map(routes, fn {path, handler} -> {compile_path(path), handler} end)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc "Returns `{:ok, handler, params}` for the first route that matches `path`, or `:error`."
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path) when is_binary(path) do
        TinyRouter.__match__(unquote(Macro.escape(compiled)), path)
      end
    end
  end

  @doc false
  def __match__(compiled, path) do
    segments = split_path(path)

    Enum.find_value(compiled, :error, fn {pattern, handler} ->
      case match_segments(pattern, segments, %{}) do
        {:ok, params} -> {:ok, handler, params}
        :error -> nil
      end
    end)
  end

  defp match_segments([], [], params), do: {:ok, params}

  defp match_segments([{:param, name} | pattern], [segment | segments], params) do
    match_segments(pattern, segments, Map.put(params, name, segment))
  end

  defp match_segments([literal | pattern], [literal | segments], params) do
    match_segments(pattern, segments, params)
  end

  defp match_segments(_pattern, _segments, _params), do: :error

  defp compile_path(path) do
    Enum.map(split_path(path), fn
      ":" <> name -> {:param, String.to_atom(name)}
      literal -> literal
    end)
  end

  defp split_path(path), do: String.split(path, "/", trim: true)

  defp validate_path!(env, path) do
    if not is_binary(path) do
      compile_error!(env, "the path must be a string literal, got #{Macro.to_string(path)}")
    end

    if ":" in split_path(path) do
      compile_error!(env, ~s(a parameter needs a name after the colon, as in "/users/:id"))
    end
  end

  defp validate_handler!(env, handler) do
    if not (is_atom(handler) and Macro.classify_atom(handler) == :alias) do
      compile_error!(
        env,
        "the handler must be a module name, such as MyApp.PageHandler, got #{Macro.to_string(handler)}"
      )
    end
  end

  defp compile_error!(env, description) do
    raise CompileError, file: env.file, line: env.line, description: description
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
