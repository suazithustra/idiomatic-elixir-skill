defmodule TinyRouter do
  @moduledoc """
  A small DSL (domain-specific language) for declaring routes and matching
  request paths against them.

  > #### `use TinyRouter` {: .info}
  >
  > When you `use TinyRouter`, it imports `get/2` and defines `routes/0` and
  > `match/1` in your module.

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

      MyApp.Router.match("/nope")
      #=> :error

  Routes are tried in declaration order and the first match wins. Empty
  segments are ignored, so `"/users/42/"` matches `"/users/:id"`. A segment
  that starts with `:` captures the request segment under that name.

  A path that is not a string, a handler that is not a module name, or an
  invalid parameter name raises `ArgumentError` when the router compiles.
  """

  @param_name ~r/\A[a-z][a-zA-Z0-9_]*\z/

  @doc false
  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route for `path` that is handled by the module `handler`.

  Raises `ArgumentError` at compile time if `path` is not a string or
  `handler` is not a module name.
  """
  defmacro get(path, handler) do
    # The handler is only stored and returned, never called here, so expanding
    # it as if inside a function avoids a compile-time dependency on it.
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:__route__, 0}})

    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  def __define__(_module, path, _handler) when not is_binary(path) do
    raise ArgumentError, "route path must be a string, got: #{inspect(path)}"
  end

  def __define__(_module, _path, handler)
      when not is_atom(handler) or handler in [nil, true, false] do
    raise ArgumentError, "route handler must be a module name, got: #{inspect(handler)}"
  end

  def __define__(module, path, handler) do
    Module.put_attribute(module, :tiny_router_routes, {path, handler, parse_path!(path)})
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()
    declared = Enum.map(routes, fn {path, handler, _segments} -> {path, handler} end)
    clauses = Enum.map(routes, &match_clause/1)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(declared))

      @doc """
      Matches a request path against the declared routes.

      Returns `{:ok, handler, params}` for the first matching route, or `:error`.
      """
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path) when is_binary(path) do
        __tiny_router_match__(String.split(path, "/", trim: true))
      end

      unquote_splicing(clauses)

      defp __tiny_router_match__(_segments), do: :error
    end
  end

  defp match_clause({_path, handler, segments}) do
    pattern = Enum.map(segments, &segment_pattern/1)

    params =
      for {:param, name} <- segments do
        {name, Macro.var(name, __MODULE__)}
      end

    quote do
      defp __tiny_router_match__(unquote(pattern)) do
        {:ok, unquote(handler), unquote({:%{}, [], params})}
      end
    end
  end

  defp segment_pattern({:literal, text}), do: text
  defp segment_pattern({:param, name}), do: Macro.var(name, __MODULE__)

  defp parse_path!(path) do
    segments =
      path
      |> String.split("/", trim: true)
      |> Enum.map(&parse_segment!(&1, path))

    names = for {:param, name} <- segments, do: name

    if names != Enum.uniq(names) do
      raise ArgumentError, "route #{inspect(path)} repeats a parameter name"
    end

    segments
  end

  defp parse_segment!(":" <> name, path) do
    if Regex.match?(@param_name, name) do
      {:param, String.to_atom(name)}
    else
      raise ArgumentError,
            "invalid parameter name #{inspect(":" <> name)} in route #{inspect(path)}"
    end
  end

  defp parse_segment!(text, _path), do: {:literal, text}
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
