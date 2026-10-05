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
  quote do
    Routes.__define__(__MODULE__, unquote(route), unquote(handler))
  end
end

@doc false
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

A module passed to a macro in a module body becomes a compile-time dependency, so changing it recompiles every caller. If the macro only stores the module to call it later from a function, expand it as if it were used inside that function:

```elixir
defmacro plug(mod) do
  mod = Macro.expand_literals(mod, %{__CALLER__ | function: {:call, 2}})

  quote do
    @plugs unquote(mod)
  end
end
```

Do this only when the macro never calls the module, reads its struct, or inspects it at compile time. Check dependencies with `mix xref trace path/to/file.ex`.

## Write module names literally

The compiler tracks dependencies only on module names it can see. `Module.concat(OtherModule, part)` or `:"Elixir.OtherModule.Foo"` hides the dependency, so changes to that module may not trigger recompilation.

```elixir
# Instead of
for part <- [:Foo, :Bar], do: Module.concat(OtherModule, part).example()
# write
for mod <- [OtherModule.Foo, OtherModule.Bar], do: mod.example()
```

If the names really must be generated, build them inside a macro with `OtherModule.unquote(part)` so the full alias exists at compile time.
