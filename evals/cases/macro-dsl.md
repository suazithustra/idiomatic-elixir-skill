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
- Handlers stay runtime dependencies: `get` keeps the alias as written or expands it with `Macro.expand_literals/2` and a function in the environment, so `mix xref trace` on a router lists `MyApp.PageHandler` as a runtime dependency, not a compile-time one. `Macro.expand/2` makes it compile-time.
- Every public function has a `@spec`, including `@doc false` ones and ones defined inside `quote`; a function under `@impl` needs none. All modules are under `TinyRouter`.
- A bad declaration fails at compile time with `ArgumentError` or `CompileError`, not at the first request.
- The file passes `mix format --check-formatted` and compiles.
- Expected reads: `macros.md` and `library-design.md`.

## Seen so far

- 2026-10-21, 93873be, claude-opus-5-5, without skill, 1 run: Builds match/1 as generated function clauses with specs and runtime-only handler dependencies; breaks Keep quote blocks small (a direct attribute write inside quote) and documents the effects of use below an example instead of at the top of @moduledoc, and uses unless.
- 2026-10-21, 93873be, claude-haiku-5-5, without skill, 1 run: Stores routes and matches at runtime through a @doc false lookup/2; breaks the spec rule, Keep quote blocks small, and the use documentation rule, plus unless, a compile-time handler dependency through Macro.expand, a catch-all match/1 and an unformatted line.
- 2026-10-21, 93873be, claude-haiku-5-5, without skill, 1 run: Generates match clauses in __before_compile__ with validation in private functions; breaks the spec rule, Keep quote blocks small, and the use documentation rule, plus a compile-time handler dependency through Macro.expand and a catch-all match/1.
- 2026-10-21, 93873be, claude-sonnet-5-5, without skill, 1 run: Generates documented, specced match clauses with validation in private functions; breaks the spec rule (split/1), Keep quote blocks small, and the use documentation rule, plus a compile-time handler dependency through Macro.expand, a nested if, a catch-all match/1 and an unformatted line.
- 2026-10-21, 93873be, claude-sonnet-5-5, without skill, 1 run: Generates documented match clauses with validation in private functions; breaks the spec rule (routes/match unspecced), Keep quote blocks small, and the use documentation rule, plus a compile-time handler dependency through Macro.expand, a nested if and a catch-all match/1.
- 2026-10-21, 93873be, claude-opus-5-5, with skill, 1 run: Validates and records routes in a @doc false function called from a one-line quote, types routes/0 and match/1 through @callback, keeps handlers runtime-only and documents use in an admonition; breaks none of the seven rules, only a one-line pipeline; read SKILL.md, macros.md and library-design.md.
- 2026-10-21, 93873be, claude-haiku-5-5, with skill, 1 run: Validates at expansion time and records through a @doc false __put_route__/3, but gives no public function a @spec, documents use in prose without an admonition, and makes handlers compile-time dependencies through Macro.expand; read SKILL.md, macros.md and library-design.md.
- 2026-10-21, 93873be, claude-haiku-5-5, with skill, 1 run: Validates at expansion time, records through __put_route__/3 and precompiles route segments, but gives no public function a @spec, states the effects of use below the example without an admonition, and makes handlers compile-time dependencies through Macro.expand; read SKILL.md, macros.md and library-design.md.
- 2026-10-21, 93873be, claude-sonnet-5-5, with skill, 1 run: Validates and records in __define__/3 called from a one-line quote and generates one match clause per route, with an admonition and runtime-only handlers; breaks the spec rule (__define__/3 has no @spec) plus a one-line pipeline; read SKILL.md, macros.md and library-design.md.
- 2026-10-21, 93873be, claude-sonnet-5-5, with skill, 1 run: Validates at expansion time, specs every public function, documents use in an admonition and keeps handlers runtime-only; breaks Keep quote blocks small with a direct attribute write in get's quote, plus a one-line pipeline; read SKILL.md, macros.md and library-design.md.
