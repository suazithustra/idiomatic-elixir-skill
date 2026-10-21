# Macro DSL

## Prompt

```text
We're publishing a small Hex package called `tiny_router`. Users declare routes in their own module like this:

defmodule MyApp.Router do
  use TinyRouter

  get "/", MyApp.PageHandler
  get "/users/:id", MyApp.UserHandler
end

After that, `MyApp.Router.routes/0` returns the declared `{path, handler}` pairs in declaration order, and `MyApp.Router.match/1` takes a request path and returns `{:ok, handler, params}` (params holds the `:id`-style segments) or `:error`. A path that is not a string, or a handler that is not a module name, must fail when MyApp.Router compiles, with a clear message.

Write the package's main module(s) to <output>/tiny_router.ex, followed by the MyApp.Router example above so the file can be compiled and tried. You may use the shell to check it compiles (Elixir <elixir-version> is installed). Reply with just the file path when done.
```

## What to check

- The `get` macro's `quote` block is small: it records the route by calling a regular function, and the validation runs in that function, not inside `quote`.
- Each macro argument is unquoted once, or bound with `bind_quoted`.
- `__using__/1` injects only what is needed (an attribute, `@before_compile` or similar) and its effects on the caller are documented at the top of `@moduledoc`.
- Functions that exist only to be called from generated code are marked `@doc false`.
- `match/1`, `routes/0`, and every helper are plain functions; only the declaration form (`get`) and `__using__/1` are macros.
- Handler modules are kept as the literal names the user wrote; nothing builds module names with `Module.concat/2` or string interpolation.
- Public functions have `@spec`s; all modules are under `TinyRouter`.
- A bad declaration fails at compile time with `ArgumentError` or `CompileError`, not at the first request.
- The file passes `mix format --check-formatted` and compiles.
- Expected reads: `macros.md` and `library-design.md`.

## Seen so far

- Not yet run.
