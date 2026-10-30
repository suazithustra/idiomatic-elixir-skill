defmodule TinyRouter do
  @moduledoc """
  Declares routes in a router module and matches request paths against them.

      defmodule MyApp.Router do
        use TinyRouter

        get "/", MyApp.PageHandler
        get "/users/:id", MyApp.UserHandler
      end

  > #### `use TinyRouter` {: .info}
  >
  > It imports `get/2`, sets `@before_compile`, and defines `match/1` and
  > `routes/0` in the caller's module. Routes are tried in declaration order,
  > and the first match wins.

  ## Compile-time checks

  `get/2` raises a `CompileError` when the path is not a string, when the
  handler is not a module name, when a `:name` segment is not a lowercase
  variable name, or when one path uses the same parameter name twice.
  """

  @doc false
  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]

      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter

      @doc """
      Matches a request path against the declared routes.

      Returns `{:ok, handler, params}` for the first matching route, where
      `params` maps each `:name` segment to its value in the path, or `:error`
      when no route matches.
      """
      @spec match(String.t()) :: {:ok, module(), %{atom() => String.t()}} | :error
      def match(path) when is_binary(path), do: match_segments(split_path(path))

      defp split_path(path), do: String.split(path, "/", trim: true)
    end
  end

  @doc """
  Declares a route from `path` to `handler`.

  `path` must be a string literal and `handler` a module name.
  """
  defmacro get(path, handler) do
    {path, handler, segments} = check_route!(path, handler, __CALLER__)

    quote do
      @tiny_router_routes {unquote(path), unquote(handler), unquote(Macro.escape(segments))}
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    routes = Enum.reverse(Module.get_attribute(env.module, :tiny_router_routes))

    pairs =
      for {path, handler, _segments} <- routes do
        {path, handler}
      end

    clauses = Enum.map(routes, &match_clause/1)

    quote do
      @doc """
      Returns the declared `{path, handler}` pairs in declaration order.
      """
      @spec routes() :: [{String.t(), module()}]
      def routes, do: unquote(Macro.escape(pairs))

      unquote_splicing(clauses)

      defp match_segments(_segments), do: :error
    end
  end

  defp check_route!(path, handler, caller) do
    path = Macro.expand(path, caller)
    handler = Macro.expand(handler, caller)

    if not is_binary(path) do
      compile_error!(caller, "route path must be a string, got: #{Macro.to_string(path)}")
    end

    if not module_name?(handler) do
      compile_error!(
        caller,
        "route handler must be a module name, got: #{Macro.to_string(handler)}"
      )
    end

    {path, handler, parse_path!(path, caller)}
  end

  defp module_name?(handler), do: is_atom(handler) and handler not in [nil, true, false]

  defp parse_path!(path, caller) do
    segments =
      for text <- String.split(path, "/", trim: true) do
        parse_segment!(text, caller)
      end

    names = for {:param, name} <- segments, do: name

    if length(Enum.uniq(names)) != length(names) do
      compile_error!(caller, "route #{inspect(path)} uses a parameter name more than once")
    end

    segments
  end

  defp parse_segment!(":" <> name = segment, caller) do
    if Regex.match?(~r/\A[a-z_][a-zA-Z0-9_]*\z/, name) do
      {:param, String.to_atom(name)}
    else
      compile_error!(
        caller,
        "route parameter #{inspect(segment)} must be a lowercase name, like :id"
      )
    end
  end

  defp parse_segment!(text, _caller), do: {:static, text}

  defp match_clause({_path, handler, segments}) do
    pattern = Enum.map(segments, &segment_pattern/1)

    bindings =
      for {:param, name} <- segments do
        {name, Macro.var(name, nil)}
      end

    quote do
      defp match_segments(unquote(pattern)) do
        {:ok, unquote(handler), %{unquote_splicing(bindings)}}
      end
    end
  end

  defp segment_pattern({:static, text}), do: text
  defp segment_pattern({:param, name}), do: Macro.var(name, nil)

  defp compile_error!(caller, description) do
    raise CompileError, file: caller.file, line: caller.line, description: description
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get("/", MyApp.PageHandler)
  get("/users/:id", MyApp.UserHandler)
end
