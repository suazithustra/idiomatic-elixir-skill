defmodule TinyRouter do
  @moduledoc """
  A small compile-time router DSL.

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.routes()
      #=> [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{id: "42"}}

  Routes are checked when the router module compiles: the path must be a
  string literal starting with `/`, and the handler must be a module name.
  The first matching route in declaration order wins. Trailing and repeated
  slashes are ignored when matching.
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route for `path` served by `handler`.
  """
  defmacro get(path, handler) do
    path = validate_path!(path, __CALLER__)
    handler = validate_handler!(handler, __CALLER__)

    quote do
      @tiny_router_routes {unquote(path), unquote(handler)}
    end
  end

  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()

    clauses =
      for {path, handler} <- routes do
        {pattern, params} = compile_path(path)

        quote do
          defp do_match(unquote(pattern)), do: {:ok, unquote(handler), unquote(params)}
        end
      end

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc """
      Matches a request path, returning `{:ok, handler, params}` or `:error`.
      """
      @spec match(String.t()) :: {:ok, module(), %{optional(atom()) => String.t()}} | :error
      def match(path) when is_binary(path), do: do_match(String.split(path, "/", trim: true))

      unquote_splicing(clauses)
      defp do_match(_segments), do: :error
    end
  end

  defp validate_path!(path, env) when is_binary(path) do
    segments = String.split(path, "/", trim: true)

    cond do
      not String.starts_with?(path, "/") ->
        compile_error!(env, "route path must start with \"/\", got: #{inspect(path)}")

      ":" in segments ->
        compile_error!(env, "route path has a parameter with no name: #{inspect(path)}")

      true ->
        names = for ":" <> name <- segments, do: name

        if names != Enum.uniq(names) do
          compile_error!(env, "route path repeats a parameter name: #{inspect(path)}")
        end

        path
    end
  end

  defp validate_path!(other, env) do
    compile_error!(env, "route path must be a string literal, got: #{Macro.to_string(other)}")
  end

  defp validate_handler!(handler, env) do
    case Macro.expand(handler, env) do
      mod when is_atom(mod) and mod not in [nil, true, false] ->
        mod

      _ ->
        compile_error!(
          env,
          "route handler must be a module name such as MyApp.Handler, got: " <>
            Macro.to_string(handler)
        )
    end
  end

  defp compile_error!(env, message) do
    raise CompileError, file: env.file, line: env.line, description: "get/2: " <> message
  end

  # Builds the quoted segment-list pattern and the quoted params map for a path.
  defp compile_path(path) do
    {pattern, params} =
      path
      |> String.split("/", trim: true)
      |> Enum.with_index()
      |> Enum.map(fn
        {":" <> name, index} ->
          var = Macro.var(:"segment_#{index}", __MODULE__)
          {var, {String.to_atom(name), var}}

        {literal, _index} ->
          {literal, nil}
      end)
      |> Enum.unzip()

    {pattern, {:%{}, [], Enum.reject(params, &is_nil/1)}}
  end
end

defmodule MyApp.PageHandler do
end

defmodule MyApp.UserHandler do
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
