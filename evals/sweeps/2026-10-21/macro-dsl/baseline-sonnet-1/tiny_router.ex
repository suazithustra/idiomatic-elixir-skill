defmodule TinyRouter do
  @moduledoc """
  A tiny compile-time router.

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

      MyApp.Router.routes()
      #=> [{"/", MyApp.PageHandler}, {"/users/:id", MyApp.UserHandler}]

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{"id" => "42"}}

  Paths must be string literals starting with `/`, and handlers must be module
  names. Anything else raises a `CompileError` when the router module compiles.
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
  Declares a route from `path` to `handler`.
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

    match_clauses = Enum.map(routes, &match_clause/1)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc """
      Matches a request path against the declared routes.

      Returns `{:ok, handler, params}` or `:error`.
      """
      @spec match(String.t()) :: {:ok, module(), %{optional(String.t()) => String.t()}} | :error
      def match(path) when is_binary(path), do: do_match(TinyRouter.split(path))
      def match(_path), do: :error

      unquote_splicing(match_clauses)
      defp do_match(_segments), do: :error
    end
  end

  @doc false
  def split(path), do: String.split(path, "/", trim: true)

  defp match_clause({path, handler}) do
    {patterns, params} =
      path
      |> split()
      |> Enum.with_index()
      |> Enum.map(fn
        {":" <> name, index} ->
          var = Macro.var(:"segment_#{index}", __MODULE__)
          {var, {name, var}}

        {literal, _index} ->
          {literal, nil}
      end)
      |> Enum.unzip()

    params_map = {:%{}, [], Enum.reject(params, &is_nil/1)}

    quote do
      defp do_match(unquote(patterns)), do: {:ok, unquote(handler), unquote(params_map)}
    end
  end

  defp validate_path!(path, caller) when is_binary(path) do
    segments = split(path)
    names = for ":" <> name <- segments, do: name

    cond do
      not String.starts_with?(path, "/") ->
        compile_error!(caller, "route path must start with \"/\", got: #{inspect(path)}")

      names != Enum.uniq(names) ->
        compile_error!(caller, "route path has a repeated parameter name: #{inspect(path)}")

      ":" in segments ->
        compile_error!(caller, "route path has an unnamed parameter: #{inspect(path)}")

      true ->
        path
    end
  end

  defp validate_path!(path, caller) do
    compile_error!(
      caller,
      "route path must be a string literal, got: #{Macro.to_string(path)}"
    )
  end

  defp validate_handler!(handler, caller) do
    case Macro.expand(handler, caller) do
      module when is_atom(module) and module not in [nil, true, false] ->
        if match?({:__aliases__, _, _}, handler) or String.starts_with?(Atom.to_string(module), "Elixir.") do
          module
        else
          not_a_module!(handler, caller)
        end

      _other ->
        not_a_module!(handler, caller)
    end
  end

  defp not_a_module!(handler, caller) do
    compile_error!(
      caller,
      "route handler must be a module name such as MyApp.PageHandler, got: #{Macro.to_string(handler)}"
    )
  end

  defp compile_error!(caller, description) do
    raise CompileError, file: caller.file, line: caller.line, description: description
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
