# Macros and compile-time code

## Write a function unless the job needs a macro

A macro is justified when the job needs something only compile time can do: new syntax for a DSL (domain-specific language), access to the caller's code as data, work done once at compile time, or a check usable in guards. For guards, use `defguard`. Everything else is a function, which is easier to read, test, and call (no `require` needed).

## Keep `quote` blocks small

Code inside `quote` is expanded and compiled at every call site. Put the logic in a regular function and have the generated code call it.

```elixir
# Instead of
defmacro get(route, handler) do
  quote do
    route = unquote(route)
    handler = unquote(handler)
    if not is_binary(route), do: raise(ArgumentError, "route must be a binary")
    if not is_atom(handler), do: raise(ArgumentError, "handler must be a module")
    @routes {route, handler}
  end
end
# write
defmacro get(route, handler) do
  handler = Macro.expand_literals(handler, %{__CALLER__ | function: {:call, 2}})

  quote do
    Routes.__define__(__MODULE__, unquote(route), unquote(handler))
  end
end

@doc false
@spec __define__(module(), String.t(), module()) :: :ok
def __define__(module, route, handler) do
  if not is_binary(route), do: raise(ArgumentError, "route must be a binary")
  if not is_atom(handler), do: raise(ArgumentError, "handler must be a module")
  Module.put_attribute(module, :routes, {route, handler})
end
```

## Unquote each argument once

Each `unquote(arg)` inserts the caller's expression again, so it is evaluated again. Bind it to a variable inside the quote, or use `bind_quoted`.

```elixir
# Instead of (runs expensive_call() twice)
defmacro double(expr) do
  quote do: unquote(expr) + unquote(expr)
end
# write
defmacro double(expr) do
  quote bind_quoted: [value: expr] do
    value + value
  end
end
```

## Offer `import` or `alias` instead of `use` when they are enough

`import` and `alias` are lexical and visible. `use MyLib` can inject any code into the caller, including further imports that conflict with the caller's own functions, and the reader cannot see what it did without reading `__using__/1`. Provide `__using__/1` only when you need to inject definitions, callbacks, or module attributes.

When you do provide `use`, keep the injected code minimal and document its effects on the caller's module in an admonition block at the top of `@moduledoc`:

```markdown
> #### `use MyLib` {: .info}
>
> When you `use MyLib`, it sets `@behaviour MyLib` and defines
> `child_spec/1`, so your module can be added to a supervision tree.
```

List only changes to the caller's public API, not private attributes.

## Avoid compile-time dependencies on modules used only at runtime

A module passed to a macro in a module body becomes a compile-time dependency, so changing it recompiles every caller. The dependency comes from the alias, so unquoting it into a call in the module body creates it, and so does expanding it against `__CALLER__` as it stands, with `Macro.expand/2` or `Macro.expand_literals/2`. If the macro only stores the module to call it later from a function, expand it in the macro body as if it were used inside that function, and pass on the atom that comes back:

```elixir
defmacro plug(mod) do
  mod = Macro.expand_literals(mod, %{__CALLER__ | function: {:call, 2}})

  quote do
    Plugs.__add__(__MODULE__, unquote(mod))
  end
end
```

The function named in the environment need not exist. A macro that must reject a bad argument when the caller compiles can still do this, by checking the expanded value: `is_atom(mod)` and `Macro.classify_atom(mod) == :alias` look at the name and not the module, so they add no dependency.

Do this only when the macro never calls the module, reads its struct, or inspects it at compile time. Check dependencies with `mix xref trace path/to/file.ex`.

## Write module names literally

The compiler tracks dependencies only on module names it can see in the code. `Module.concat(OtherModule, part)` builds the name at runtime, so changes to that module do not trigger recompilation of the caller.

```elixir
# Instead of
for part <- [:Foo, :Bar] do
  Module.concat(OtherModule, part).example()
end
# write
for mod <- [OtherModule.Foo, OtherModule.Bar] do
  mod.example()
end
```

If the names really must be generated, build the full name inside a macro and unquote it, so the expanded code contains the literal module name and `mix xref` can see it:

```elixir
defmacro call_example(part) do
  mod = Module.concat(OtherModule, part)
  quote do: unquote(mod).example()
end
```

## Give macros called without parentheses a `.formatter.exs`

`mix format` adds parentheses to every call it has not been told about, so a declaration written `get "/", MyApp.PageHandler` comes out as `get("/", MyApp.PageHandler)`, and `--check-formatted` fails on the bare form. A macro designed to be called without parentheses, as a DSL (domain-specific language) usually is, goes under `locals_without_parens` in a `.formatter.exs` at the package root, with the same list under `export` so projects that use the package pick it up through `import_deps: [:my_package]`.

```elixir
locals_without_parens = [get: 2]

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens]
]
```

The file is part of the package, so it stays after the work is done, even when the task names only the code. `mix format` reads it from the current directory, so run the format check from the folder that holds it. Parentheses the formatter added to such a call mean the file is missing: write it and put the call back as it was declared.
