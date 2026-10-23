defmodule TinyRouter do
  @moduledoc """
  A tiny compile-time router DSL.

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.routes()
      #=> [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{"id" => "42"}}

  Segments starting with `:` capture the request segment under a string key.
  Routes are tried in declaration order; the first match wins.
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route for `path`, dispatched to the module `handler`.

  Raises `CompileError` unless `path` is a string starting with `/` and
  `handler` is a module name.
  """
  defmacro get(path, handler) do
    path = validate_path!(path, __CALLER__)
    handler = validate_handler!(handler, __CALLER__)
    segments = parse_segments!(path, __CALLER__)

    quote do
      @tiny_router_routes {unquote(path), unquote(handler), unquote(Macro.escape(segments))}
    end
  end

  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()

    clauses =
      for {_path, handler, segments} <- routes do
        {patterns, bindings} = build_pattern(segments)

        quote do
          defp do_match(unquote(patterns)), do: {:ok, unquote(handler), %{unquote_splicing(bindings)}}
        end
      end

    declared = for {path, handler, _segments} <- routes, do: {path, handler}

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(declared)

      @doc """
      Matches a request path against the declared routes.

      Returns `{:ok, handler, params}` or `:error`.
      """
      @spec match(term()) :: {:ok, module(), %{optional(String.t()) => String.t()}} | :error
      def match(path) when is_binary(path), do: path |> TinyRouter.split() |> do_match()
      def match(_path), do: :error

      unquote_splicing(clauses)
      defp do_match(_segments), do: :error
    end
  end

  @doc false
  def split(path), do: String.split(path, "/", trim: true)

  defp build_pattern(segments) do
    {patterns, bindings} =
      segments
      |> Enum.with_index()
      |> Enum.map(fn
        {{:literal, text}, _i} ->
          {text, nil}

        {{:param, name}, i} ->
          var = Macro.var(:"param_#{i}", __MODULE__)
          {var, {name, var}}
      end)
      |> Enum.unzip()

    {patterns, Enum.reject(bindings, &is_nil/1)}
  end

  defp validate_path!(path, caller) when is_binary(path) do
    unless String.starts_with?(path, "/") do
      compile_error!(caller, "route path must start with \"/\", got: #{inspect(path)}")
    end

    path
  end

  defp validate_path!(other, caller) do
    compile_error!(
      caller,
      "route path must be a string literal, got: #{Macro.to_string(other)}"
    )
  end

  defp validate_handler!(handler, caller) do
    case Macro.expand(handler, caller) do
      mod when is_atom(mod) and mod not in [nil, true, false] ->
        mod

      _ ->
        compile_error!(
          caller,
          "route handler must be a module name (e.g. MyApp.Handler), got: " <>
            Macro.to_string(handler)
        )
    end
  end

  defp parse_segments!(path, caller) do
    segments =
      path
      |> split()
      |> Enum.map(fn
        ":" -> compile_error!(caller, "empty parameter name in route #{inspect(path)}")
        ":" <> name -> {:param, name}
        text -> {:literal, text}
      end)

    names = for {:param, name} <- segments, do: name

    if names != Enum.uniq(names) do
      compile_error!(caller, "duplicate parameter name in route #{inspect(path)}")
    end

    segments
  end

  defp compile_error!(caller, message) do
    raise CompileError, file: caller.file, line: caller.line, description: message
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
