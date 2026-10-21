defmodule TinyRouter do
  @moduledoc """
  A small DSL (domain-specific language) for declaring routes.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports the `get/2` macro and defines
  > `routes/0` and `match/1` in your module.

  ## Examples

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

  A path or handler that is not valid makes the router module fail to compile.
  Param names are strings, as in Plug and Phoenix.
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
  Declares a route from `path` to `handler`.

  `path` must be a string literal and `handler` a module name.
  """
  defmacro get(path, handler) do
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:routes, 0}})
    route = validate_route!(__CALLER__, path, handler)

    quote do
      @tiny_router_routes unquote(Macro.escape(route))
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc """
      Matches a request path.

      Returns `{:ok, handler, params}` or `:error`.
      """
      @spec match(String.t()) :: {:ok, module(), %{optional(String.t()) => String.t()}} | :error
      def match(path) when is_binary(path) do
        match_segments(TinyRouter.split(path))
      end

      unquote_splicing(Enum.map(routes, &match_clause/1))
      defp match_segments(_segments), do: :error
    end
  end

  @doc false
  @spec split(String.t()) :: [String.t()]
  def split(path), do: String.split(path, "/", trim: true)

  defp validate_route!(env, path, handler) do
    cond do
      not is_binary(path) ->
        compile_error!(env, "route path must be a string literal, got: #{Macro.to_string(path)}")

      not String.starts_with?(path, "/") ->
        compile_error!(env, "route path must start with \"/\", got: #{inspect(path)}")

      not is_atom(handler) or handler in [nil, true, false] ->
        compile_error!(
          env,
          "route handler must be a module name, got: #{Macro.to_string(handler)}"
        )

      true ->
        {path, handler}
    end
  end

  defp compile_error!(env, description) do
    raise CompileError, file: env.file, line: env.line, description: description
  end

  defp match_clause({path, handler}) do
    {patterns, params} =
      path
      |> split()
      |> Enum.with_index()
      |> Enum.map(&segment_pattern/1)
      |> Enum.unzip()

    params = for {name, var} <- params, name != nil, do: {name, var}

    quote do
      defp match_segments(unquote(patterns)) do
        {:ok, unquote(handler), %{unquote_splicing(params)}}
      end
    end
  end

  defp segment_pattern({":" <> name, index}) do
    var = Macro.var(:"param_#{index}", __MODULE__)
    {var, {name, var}}
  end

  defp segment_pattern({literal, _index}), do: {literal, {nil, nil}}
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
