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
      #=> {:ok, MyApp.UserHandler, %{"id" => "42"}}

      MyApp.Router.match("/nope")
      #=> :error

  Routes are tried in declaration order. Params are returned as a map with
  string keys. Empty path segments are ignored, so `"/users//42/"` matches
  `"/users/:id"`.

  A path that is not a string literal starting with `/`, or a handler that is
  not a module name, raises a `CompileError` when the router module compiles.
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
  Declares a route for `path` handled by the module `handler`.
  """
  defmacro get(path, handler) do
    path = validate_path!(path, __CALLER__)
    handler = validate_handler!(handler, __CALLER__)
    validate_params!(path, __CALLER__)

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

    clauses =
      for {path, handler} <- routes do
        {patterns, params} = compile_path(path)

        quote do
          defp do_match(unquote(patterns)), do: {:ok, unquote(handler), unquote(params)}
        end
      end

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc """
      Matches a request path. Returns `{:ok, handler, params}` or `:error`.
      """
      @spec match(String.t()) :: {:ok, module(), %{optional(String.t()) => String.t()}} | :error
      def match(path) when is_binary(path), do: do_match(String.split(path, "/", trim: true))

      unquote_splicing(clauses)
      defp do_match(_segments), do: :error
    end
  end

  # Builds the segment-list pattern and the params map expression for a path.
  defp compile_path(path) do
    {patterns, bindings} =
      path
      |> String.split("/", trim: true)
      |> Enum.with_index()
      |> Enum.map_reduce([], fn
        {":" <> name, index}, bindings ->
          var = Macro.var(:"param_#{index}", __MODULE__)
          {var, [{name, var} | bindings]}

        {segment, _index}, bindings ->
          {segment, bindings}
      end)

    {patterns, {:%{}, [], Enum.reverse(bindings)}}
  end

  defp validate_path!(path, env) when is_binary(path) do
    if String.starts_with?(path, "/") do
      path
    else
      raise_error!(env, "route path must start with \"/\", got: #{inspect(path)}")
    end
  end

  defp validate_path!(other, env) do
    raise_error!(env, "route path must be a string literal, got: #{Macro.to_string(other)}")
  end

  defp validate_params!(path, env) do
    names =
      for ":" <> name <- String.split(path, "/", trim: true), do: name

    if "" in names or length(names) != length(Enum.uniq(names)) do
      raise_error!(env, "empty or duplicate parameter name in route path #{inspect(path)}")
    end
  end

  defp validate_handler!(handler, env) do
    case Macro.expand(handler, env) do
      mod when is_atom(mod) and mod not in [nil, true, false] ->
        mod

      _ ->
        raise_error!(env, "route handler must be a module name, got: #{Macro.to_string(handler)}")
    end
  end

  defp raise_error!(env, message) do
    raise CompileError, file: env.file, line: env.line, description: "TinyRouter: " <> message
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
