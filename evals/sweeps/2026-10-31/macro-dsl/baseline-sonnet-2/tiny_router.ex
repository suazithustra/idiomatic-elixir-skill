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

  Segments starting with `:` capture the request segment under a string key.
  Leading, trailing and repeated slashes in a request path are ignored.
  Routes are tried in declaration order.
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route. `path` must be a string literal and `handler` a module name.
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
        {segments, params} = compile_path(path, env)

        quote do
          defp do_match(unquote(segments)) do
            {:ok, unquote(handler), %{unquote_splicing(params)}}
          end
        end
      end

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc """
      Matches a request path against the declared routes.

      Returns `{:ok, handler, params}` or `:error`.
      """
      @spec match(term()) :: {:ok, module(), %{optional(String.t()) => String.t()}} | :error
      def match(path) when is_binary(path), do: do_match(TinyRouter.split(path))
      def match(_path), do: :error

      unquote_splicing(clauses)
      defp do_match(_segments), do: :error
    end
  end

  @doc false
  def split(path), do: String.split(path, "/", trim: true)

  # Turns "/users/:id" into a list pattern like ["users", id_var] plus
  # [{"id", id_var}] entries for the params map.
  defp compile_path(path, env) do
    {segments, params} =
      path
      |> split()
      |> Enum.with_index()
      |> Enum.map(fn
        {":" <> name, index} ->
          if name == "" do
            compile_error!(env, "route #{inspect(path)} has an empty parameter name")
          end

          var = Macro.var(:"param_#{index}", __MODULE__)
          {var, {name, var}}

        {literal, _index} ->
          {literal, nil}
      end)
      |> Enum.unzip()

    params = Enum.reject(params, &is_nil/1)
    names = Enum.map(params, &elem(&1, 0))

    if names != Enum.uniq(names) do
      compile_error!(env, "route #{inspect(path)} repeats a parameter name")
    end

    {segments, params}
  end

  defp validate_path!(path, _env) when is_binary(path), do: path

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
    raise CompileError, file: env.file, line: env.line, description: "TinyRouter: " <> message
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
