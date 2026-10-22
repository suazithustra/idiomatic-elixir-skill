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

      MyApp.Router.match("/nope")
      #=> :error

  Paths must be string literals starting with `/`, and handlers must be module
  names. Anything else raises an `ArgumentError` when the router compiles.
  """

  defmacro __using__(_opts) do
    quote do
      import TinyRouter, only: [get: 2]
      Module.register_attribute(__MODULE__, :tiny_router_routes, accumulate: true)
      @before_compile TinyRouter
    end
  end

  @doc """
  Declares a route for `path` served by `handler`.
  """
  defmacro get(path, handler) do
    handler = Macro.expand(handler, __CALLER__)
    path = validate_path!(path)
    handler = validate_handler!(handler)

    quote do
      @tiny_router_routes {unquote(path), unquote(handler)}
    end
  end

  defmacro __before_compile__(env) do
    routes = env.module |> Module.get_attribute(:tiny_router_routes) |> Enum.reverse()

    clauses =
      for {path, handler} <- routes do
        {segments, params} = compile_path(path)

        quote do
          defp do_match(unquote(segments)), do: {:ok, unquote(handler), %{unquote_splicing(params)}}
        end
      end

    quote do
      @doc "Returns the declared `{path, handler}` pairs in declaration order."
      def routes, do: unquote(Macro.escape(routes))

      @doc """
      Matches a request path, returning `{:ok, handler, params}` or `:error`.
      """
      def match(path) when is_binary(path), do: do_match(String.split(path, "/", trim: true))
      def match(_path), do: :error

      unquote_splicing(clauses)
      defp do_match(_segments), do: :error
    end
  end

  defp compile_path(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(fn
      ":" <> name ->
        var = Macro.var(String.to_atom(name), __MODULE__)
        {var, {name, var}}

      literal ->
        {literal, nil}
    end)
    |> Enum.unzip()
    |> then(fn {segments, params} -> {segments, Enum.reject(params, &is_nil/1)} end)
  end

  defp validate_path!(path) when is_binary(path) do
    unless String.starts_with?(path, "/") do
      raise ArgumentError, "route path must start with \"/\", got: #{inspect(path)}"
    end

    names =
      for ":" <> name <- String.split(path, "/", trim: true), do: name

    if "" in names do
      raise ArgumentError, "route path has an unnamed parameter segment: #{inspect(path)}"
    end

    if length(names) != length(Enum.uniq(names)) do
      raise ArgumentError, "route path repeats a parameter name: #{inspect(path)}"
    end

    path
  end

  defp validate_path!(other) do
    raise ArgumentError,
          "route path must be a string literal, got: #{Macro.to_string(other)}"
  end

  defp validate_handler!(handler) when is_atom(handler) and handler not in [nil, true, false],
    do: handler

  defp validate_handler!(other) do
    raise ArgumentError,
          "route handler must be a module name (e.g. MyApp.PageHandler), got: " <>
            Macro.to_string(other)
  end
end

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end
