defmodule TinyRouter do
  @moduledoc """
  A small DSL (domain-specific language) for declaring routes.

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
      #=> {:ok, MyApp.UserHandler, %{id: "42"}}

      MyApp.Router.match("/missing")
      #=> :error

  A path that is not a string starting with `/`, a handler that is not a
  module name, or a repeated `:name` segment in one path raises
  `ArgumentError` when the router module compiles.
  """

  @doc false
  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route for `path`, served by the `handler` module.

  Segments written as `:name` match any value and are returned in the
  params map under the atom `:name`.
  """
  defmacro get(path, handler) do
    # The handler is only stored, never called here, so expanding it as if it
    # sat inside a function avoids a compile-time dependency on it.
    handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:match, 1}})

    quote do
      TinyRouter.__define__(__MODULE__, unquote(path), unquote(handler))
    end
  end

  @doc false
  @spec __define__(module(), String.t(), module()) :: :ok
  def __define__(module, "/" <> _rest = path, handler) do
    validate_handler!(handler)
    validate_params!(path)
    Module.put_attribute(module, :tiny_routes, {path, handler})
  end

  def __define__(_module, path, _handler) do
    raise ArgumentError,
          "TinyRouter route path must be a string starting with \"/\", got: #{inspect(path)}"
  end

  @doc false
  defmacro __before_compile__(env) do
    routes =
      env.module
      |> Module.get_attribute(:tiny_routes)
      |> Enum.reverse()

    clauses = Enum.map(routes, &match_clause/1)

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(routes))

      @doc """
      Matches a request path against the declared routes.

      Returns `{:ok, handler, params}` for the first matching route, or `:error`.
      """
      @spec match(String.t()) :: {:ok, module(), %{optional(atom()) => String.t()}} | :error
      def match(path) when is_binary(path), do: match_segments(TinyRouter.__segments__(path))

      unquote_splicing(clauses)

      defp match_segments(_segments), do: :error
    end
  end

  @doc false
  @spec __segments__(String.t()) :: [String.t()]
  def __segments__(path), do: String.split(path, "/", trim: true)

  defp match_clause({path, handler}) do
    segments = __segments__(path)
    pattern = Enum.map(segments, &segment_pattern/1)
    params = for ":" <> name <- segments, do: {param_key(name), param_var(name)}

    quote do
      defp match_segments(unquote(pattern)) do
        {:ok, unquote(handler), unquote({:%{}, [], params})}
      end
    end
  end

  defp segment_pattern(":" <> name), do: param_var(name)
  defp segment_pattern(literal), do: literal

  # Names come from the router author's own source, read once at compile time.
  defp param_key(name), do: String.to_atom(name)
  defp param_var(name), do: Macro.var(param_key(name), nil)

  defp validate_handler!(handler) do
    if not module_name?(handler) do
      raise ArgumentError,
            "TinyRouter handler must be a module name, got: #{inspect(handler)}"
    end
  end

  defp module_name?(handler) when is_atom(handler) do
    String.starts_with?(Atom.to_string(handler), "Elixir.")
  end

  defp module_name?(_handler), do: false

  defp validate_params!(path) do
    names = for ":" <> name <- __segments__(path), do: name

    if names != Enum.uniq(names) do
      raise ArgumentError, "TinyRouter path #{inspect(path)} repeats a :name segment"
    end
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
