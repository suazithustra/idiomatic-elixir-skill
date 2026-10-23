defmodule TinyRouter do
  @moduledoc """
  A tiny compile-time router DSL.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0`
  > and `match/1` in your module.

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

  A path that is not a string, or a handler that is not a module name,
  raises `ArgumentError` when the router module compiles. The first route
  that matches a request path wins.
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
  Declares a route for `path`, handled by the module `handler`.

  Segments starting with `:` capture the matching request segment.
  """
  defmacro get(path, handler) do
    # The handler is only stored, never called here, so expanding it as if
    # used inside a function avoids a compile-time dependency on it.
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:match, 1}})

    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(:tiny_router_routes)
      |> Enum.reverse()

    match_clauses = Enum.map(routes, &match_clause/1)

    quote do
      @doc """
      Returns the declared `{path, handler}` pairs in declaration order.
      """
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc """
      Matches a request path against the declared routes.

      Returns `{:ok, handler, params}` or `:error`.
      """
      @spec match(String.t()) :: {:ok, module(), %{optional(String.t()) => String.t()}} | :error
      def match(path) when is_binary(path) do
        match_segments(TinyRouter.split(path))
      end

      unquote_splicing(match_clauses)

      defp match_segments(_segments), do: :error
    end
  end

  @doc false
  @spec __define__(module(), term(), term()) :: :ok
  def __define__(module, path, handler) when is_binary(path) and is_atom(handler) do
    if handler in [nil, true, false] do
      raise ArgumentError, "expected a handler module name, got: #{inspect(handler)}"
    end

    if not String.starts_with?(path, "/") do
      raise ArgumentError, ~s(expected a route path starting with "/", got: #{inspect(path)})
    end

    Module.put_attribute(module, :tiny_router_routes, {path, handler})
  end

  def __define__(_module, path, _handler) when not is_binary(path) do
    raise ArgumentError, "expected a route path to be a string, got: #{inspect(path)}"
  end

  def __define__(_module, _path, handler) do
    raise ArgumentError, "expected a handler module name, got: #{inspect(handler)}"
  end

  @doc false
  @spec split(String.t()) :: [String.t()]
  def split(path), do: String.split(path, "/", trim: true)

  defp match_clause({path, handler}) do
    {patterns, params} =
      path
      |> split()
      |> Enum.with_index()
      |> Enum.map(&segment_pattern/1)
      |> Enum.unzip()

    params = Enum.reject(params, &is_nil/1)

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

  defp segment_pattern({literal, _index}), do: {literal, nil}
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
