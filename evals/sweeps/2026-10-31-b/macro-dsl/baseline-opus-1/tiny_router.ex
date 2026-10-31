defmodule TinyRouter do
  @moduledoc """
  A small router whose routes are declared at compile time.

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

  `use TinyRouter` defines two functions in the calling module:

    * `routes/0` returns the declared `{path, handler}` pairs in declaration order.

    * `match/1` takes a request path and returns `{:ok, handler, params}`, or
      `:error` if no route matches.

  ## Matching

  A path segment that starts with `:` captures the matching segment of the
  request path. `params` is a map with string keys, the same shape as Plug's
  `path_params`:

      MyApp.Router.match("/users/42")
      #=> {:ok, MyApp.UserHandler, %{"id" => "42"}}

      MyApp.Router.match("/nope")
      #=> :error

  Routes are tried in declaration order, so declare `/users/new` before
  `/users/:id`. Empty segments are ignored, so `/users/42/` matches the same
  route as `/users/42`. Captured values are returned as they appear in the
  path, without URL decoding.

  ## Compile-time checks

  A path must be a string, and a handler must be an Elixir module name. Anything
  else raises a `CompileError` that points at the offending `get` line. A path
  also may not repeat a parameter name or contain a `:` with no name after it.

  Handler modules do not have to exist yet. They are not loaded, so a router
  does not recompile when a handler changes.

  ## Formatting

  `mix format` adds parentheses to `get` calls unless your `.formatter.exs` has
  `locals_without_parens: [get: 2]`.
  """

  @typedoc "Values captured from `:name` path segments, keyed by name."
  @type params :: %{optional(String.t()) => String.t()}

  @doc false
  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route from `path` to the `handler` module.

  `path` and `handler` can be any expression that the module body can evaluate,
  such as a module attribute or a `for` variable.
  """
  defmacro get(path, handler) do
    # Expanding the alias as if inside a function stops the router from taking
    # a compile-time dependency on each handler.
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:routes, 0}})

    quote do
      TinyRouter.__route__(__ENV__, unquote(path), unquote(handler))
    end
  end

  @doc false
  def __route__(env, path, handler) do
    with :ok <- validate_path(path),
         :ok <- validate_handler(handler) do
      Module.put_attribute(env.module, :tiny_router_routes, {path, handler})
    else
      {:error, message} ->
        raise CompileError, file: env.file, line: env.line, description: message
    end
  end

  @doc false
  def __split__(path), do: String.split(path, "/", trim: true)

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()

    match_clauses =
      for {path, handler} <- routes do
        {pattern, params} = compile_path(path)

        quote do
          defp __match__(unquote(pattern)), do: {:ok, unquote(handler), unquote(params)}
        end
      end

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc "Returns `{:ok, handler, params}` for the first route matching `path`, else `:error`."
      @spec match(String.t()) :: {:ok, module(), TinyRouter.params()} | :error
      def match(path) when is_binary(path), do: path |> TinyRouter.__split__() |> __match__()

      unquote_splicing(match_clauses)
      defp __match__(_segments), do: :error
    end
  end

  defp validate_path(path) when is_binary(path) do
    names = for ":" <> name <- __split__(path), do: name

    cond do
      "" in names -> {:error, "route path #{inspect(path)} has a parameter with no name"}
      names != Enum.uniq(names) -> {:error, "route path #{inspect(path)} repeats a parameter"}
      true -> :ok
    end
  end

  defp validate_path(path), do: {:error, "route path must be a string, got: #{inspect(path)}"}

  defp validate_handler(handler) do
    if is_atom(handler) and Macro.classify_atom(handler) == :alias do
      :ok
    else
      {:error, "route handler must be a module name, got: #{inspect(handler)}"}
    end
  end

  defp compile_path(path) do
    {pattern, params} =
      path
      |> __split__()
      |> Enum.map_reduce([], fn
        ":" <> name, params ->
          var = Macro.unique_var(:param, __MODULE__)
          {var, [{name, var} | params]}

        literal, params ->
          {literal, params}
      end)

    {pattern, {:%{}, [], params}}
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
