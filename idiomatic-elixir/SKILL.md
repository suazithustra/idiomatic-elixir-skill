---
name: idiomatic-elixir
description: Rules for idiomatic Elixir that correct the common mistakes in generated code, covering pattern matching, error handling, collections, naming, readability, and OTP processes. Use whenever writing, editing, refactoring, or reviewing Elixir code (.ex or .exs files, Mix projects), including Phoenix, Ecto, ExUnit tests, GenServers, macros, and Hex libraries.
license: Apache-2.0
---

# Idiomatic Elixir

Readability rules carry the same weight as correctness rules.

## How to use this skill

- **Reference files:** besides following the rules below, read each reference file whose trigger appears in the code or the task:

  | If the code or task involves | Read |
  | --- | --- |
  | `GenServer`, `Agent`, `Task`, `spawn`, `send`, `:ets`, a supervisor, or shared state | `references/processes.md` |
  | a Hex package, or a public module API other code depends on | `references/library-design.md` |
  | `defmacro`, `quote`, `__using__`, or `use` of your own module | `references/macros.md` |
  | `ExUnit`, files under `test/` | `references/testing.md` |
  | `Repo`, `Ecto`, schemas, migrations, Phoenix controllers, contexts, or LiveViews | `references/ecto-phoenix.md` |

- **Reviewing code:** report a finding only where the code contains the pattern a rule describes. For each finding, name the rule, quote the line, and show the fix. If you also write an improved version, it must apply every finding you reported.
- **Existing projects:** follow the project's established conventions where they conflict with a readability rule here, and say so when you do.

## Pattern matching and data access

### Read required keys with `map.key` or a pattern; keep `map[:key]` for optional keys

`map[:key]` and `Map.get/2` return `nil` for a missing key, so the mistake surfaces later, somewhere else, as a confusing error. `map.key` raises `KeyError` where the mistake is. Structs do not implement `Access`: `user[:name]` raises `UndefinedFunctionError`, so read struct fields with `user.name` or a pattern.

```elixir
# Instead of (x and y are required, z is optional)
{point[:x], point[:y], point[:z]}
# write
{point.x, point.y, point[:z]}
```

### Match every expected shape and let unexpected ones crash

A `_ ->` clause after `{:ok, value}` turns every other return value, including ones added later, into the same error and hides bugs. Match the error shape explicitly. Destructure results with a pattern so malformed input raises at the cause instead of producing wrong values.

```elixir
# Instead of
case File.read(path) do
  {:ok, contents} -> parse(contents)
  _ -> {:error, :unreadable}
end
# write
case File.read(path) do
  {:ok, contents} -> parse(contents)
  {:error, reason} -> {:error, {:unreadable, reason}}
end

# Instead of
key = Enum.at(parts, 0)
value = Enum.at(parts, 1)
# write
[key, value] = String.split(pair, "=", parts: 2)
```

When the input set is open by design (event types from an external system, messages from other processes), end with a clause that binds and names what it catches: `defp parse_event(type, _data), do: {:error, {:unsupported_event, type}}`. Make sure that clause can only receive what its error names. If one set of clauses both selects the event type and matches its fields, a known type with a missing field falls through to "unsupported event". Select the type in one function and validate the fields in another.

### In multi-clause functions, bind in the head only what patterns and guards use

When a function has several clauses, binding body-only fields in every head makes it hard to see what selects each clause.

```elixir
# Instead of
def drive(%User{name: name, age: age}) when age >= 18, do: "#{name} can drive"
def drive(%User{name: name, age: age}) when age < 18, do: "#{name} cannot drive"
# write
def drive(%User{age: age} = user) when age >= 18, do: "#{user.name} can drive"
def drive(%User{age: age} = user) when age < 18, do: "#{user.name} cannot drive"
```

### Update structs with `%{struct | field: value}`

The update syntax raises if the field does not exist. `Map.put/3` with a misspelled key silently produces a broken struct.

### Convert external strings to atoms with explicit clauses

Atoms are never garbage-collected and the VM (virtual machine) has a fixed atom limit, 1,048,576 by default. `String.to_atom/1` on input lets anyone who controls the input exhaust it and crash the node. The same applies to `keys: :atoms` in JSON decoders. List the accepted values instead:

```elixir
defp parse_status("active"), do: {:ok, :active}
defp parse_status("suspended"), do: {:ok, :suspended}
defp parse_status(other), do: {:error, {:unknown_status, other}}
```

`String.to_existing_atom/1` is acceptable only when every valid atom appears literally in the same module, for example in a function that lists them. Atoms that appear only in a module attribute or the module body do not count.

## Control flow and errors

### Branch with function clauses and guards before reaching for `if` or `cond`

```elixir
# Instead of
def shipping_cost(order) do
  if order.country == "US" do
    if order.total >= 5000, do: 0, else: 500
  else
    1500
  end
end
# write
def shipping_cost(%Order{country: "US", total: total}) when total >= 5000, do: 0
def shipping_cost(%Order{country: "US"}), do: 500
def shipping_cost(%Order{}), do: 1500
```

Clauses of one function must do one related job. If the clauses do unrelated things for different inputs (updating a product versus updating an animal), write separate functions (`update_product/1`, `update_animal/1`).

Use `if` for a single boolean condition, not `case flag do true -> ...; false -> ... end` and not a `cond` with one condition plus `true ->`. Do not use `unless`, which is deprecated: write `if` with a positive condition or `not`.

### Chain fallible steps with `with`; normalize each step's error in a small private function

A large `else` block that maps errors back to steps is hard to follow and breaks when two steps fail with the same shape. Give each step a private function that returns `{:ok, value}` or `{:error, reason}`, and let `with` pass the error through unchanged. Use `case` when there is only one step.

```elixir
# Instead of
with {:ok, encoded} <- File.read(path),
     {:ok, decoded} <- Base.decode64(encoded) do
  {:ok, String.trim(decoded)}
else
  {:error, _} -> {:error, :badfile}
  :error -> {:error, :badencoding}
end
# write
with {:ok, encoded} <- read_file(path),
     {:ok, decoded} <- decode64(encoded) do
  {:ok, String.trim(decoded)}
end

defp read_file(path) do
  case File.read(path) do
    {:ok, contents} -> {:ok, contents}
    {:error, _reason} -> {:error, :badfile}
  end
end

defp decode64(encoded) do
  case Base.decode64(encoded) do
    {:ok, decoded} -> {:ok, decoded}
    :error -> {:error, :badencoding}
  end
end
```

### Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs

Do not wrap a raising call in `try/rescue` to get a tuple. Call the non-raising version instead: `File.read/1`, `Integer.parse/1`, `DateTime.from_unix/1`, `Repo.insert/1`. Use `rescue` only around third-party code that has no non-raising version, and rescue the specific exception, never `rescue _ ->` or `rescue e ->` around a whole function.

Use atoms, tagged tuples, or exception structs as error reasons, not strings: `{:error, :not_found}`, `{:error, {:missing_field, "amount"}}`, `{:error, %MyApp.Error{}}`. Callers can match on those. A string can only be displayed.

A function ending in `!` raises instead of returning a tuple. Write it on top of the non-bang version. Call bang functions where failure means a bug, such as in scripts, tests, seeds, and boot-time setup. Do not call them on user-supplied input in a request path unless the framework turns the exception into a response.

### Use `and`, `or`, `not` when the operands are booleans

`and`, `or`, and `not` raise if their first operand is not a boolean, so they document and check intent. `&&`, `||`, and `!` accept any value. Keep those for truthy defaults such as `opts[:name] || "anonymous"`.

```elixir
# Instead of
if is_binary(name) && age >= 18 do
# write
if is_binary(name) and age >= 18 do
```

### Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it

Variables rebound inside `if`, `case`, `fn`, or `Enum.each/2` are local to that block. The outer variable keeps its old value, and the compiler warns that the inner variable is unused.

```elixir
# Instead of (both stay unchanged)
if valid?(item), do: accepted = [item | accepted]
Enum.each(items, fn item -> total = total + item.price end)
# write
accepted = if valid?(item), do: [item | accepted], else: accepted
total = Enum.sum_by(items, & &1.price)
```

Use `Enum.each/2` only for side effects. When you need results, use `Enum.map/2`, `Enum.reduce/3`, or a `for` comprehension.

## Collections

### Use the `Enum` or `Map` function made for the job

| Instead of | Write |
| --- | --- |
| `Enum.reduce(users, %{}, fn u, acc -> Map.put(acc, u.id, u) end)` | `Map.new(users, &{&1.id, &1})` |
| `Enum.into(pairs, %{})` | `Map.new(pairs)` |
| `Enum.map(items, &f/1) \|> Enum.join(", ")` | `Enum.map_join(items, ", ", &f/1)` |
| `Enum.reduce(items, 0, &(&1.amount + &2))` | `Enum.sum_by(items, & &1.amount)` (Elixir 1.18+) |
| `Enum.filter(items, &f/1) \|> Enum.count()` | `Enum.count(items, &f/1)` |
| `Enum.group_by(items, &k/1) \|> Map.new(fn {k, v} -> {k, length(v)} end)` | `Enum.frequencies_by(items, &k/1)` |
| `Enum.sort(items) \|> Enum.reverse()` | `Enum.sort(items, :desc)` |
| `Enum.find(items, &f/1) != nil` | `Enum.any?(items, &f/1)` |
| `if Map.has_key?(map, k), do: Map.get(map, k)` | `case Map.fetch(map, k) do` |
| `Map.put(map, k, f.(Map.get(map, k)))` | `Map.update!(map, k, f)` |

### Treat lists as linked lists

`length/1` and `Enum.at/2` walk the list. `acc ++ [item]` copies `acc` every time, so a loop that appends is quadratic. Build lists with `Enum.map/2` or a comprehension, or prepend with `[item | acc]` and reverse once at the end. Check for empty lists with `list == []` or a `[]` / `[_ | _]` pattern, not `length(list) == 0`. When you need an element's position, use `Enum.with_index/2` or `Enum.zip/2` instead of indexing in a loop.

### Compare dates, times, and decimals with their module functions

`<`, `>`, `Enum.max/1`, and `Enum.sort/1` compare structs field by field, which gives wrong answers: `~D[2024-01-10] > ~D[2023-02-20]` is `false`. Use `Date.compare/2`, `Date.before?/2`, `DateTime.after?/2`, `Decimal.compare/2`, and pass the module to sorting functions:

```elixir
latest = Enum.max(dates, Date)
newest_first = Enum.sort_by(events, & &1.inserted_at, {:desc, DateTime})
```

### Store and compute money as integer minor units or `Decimal`, never floats

Keep amounts as integer minor units (cents) or `Decimal`, and compute percentages with integer arithmetic so you choose the rounding. Floats can't represent most decimal fractions exactly: `90 * 0.7` is `62.99999999999999`, so `trunc(90 * 0.7)` returns `62` instead of `63`.

```elixir
# Instead of
discounted = trunc(subtotal * 0.7)
# write (30% off, rounded down)
discounted = div(subtotal * 70, 100)
# or (30% off, to the nearest cent, halves up)
discounted = div(subtotal * 70 + 50, 100)
```

## Modeling data

### Parse external data into structs where it enters the system

Strings and string-keyed maps from JSON, CSV, forms, or other services should become structs (or atom-keyed data) at the boundary, with validation. Inner functions then match on `%Address{}` instead of re-parsing a string or checking keys. Define structs with `@enforce_keys` for the required fields and a `@type t`.

Match the required keys of string-keyed input in a function head or `case`, and give the no-match case its own clause, instead of reading each key with `params["key"]` and checking for `nil`. When the caller needs to know which field is missing or invalid, check the fields one at a time in small functions chained with `with`, each returning `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}`. Do not guess the missing field from which other keys matched.

### Use one atom-valued field or option instead of overlapping booleans

```elixir
# Instead of
process(invoice, admin: true, editor: false)
import_user(params, notify: true, silent: false)
# write
process(invoice, role: :admin)
import_user(params, notify: true)
```

Two booleans overlap when one overrides the other or some combinations make no sense (`notify: true, silent: true`). Prefer an atom even for a single yes/no state that may grow, such as `status: :approved` instead of `approved: true`.

### Group related parameters

Long parameter lists are easy to call with arguments in the wrong order. Pass related values as one struct or map. Put optional settings in a keyword list as the last argument (`opts \\ []`), check them with `Keyword.validate!/2`, and document each one under `## Options` in `@doc`.

### Give each function one return shape

Options must not change what a function returns. If one mode returns an integer and another returns a tuple, write two functions: `parse/1` and `parse_discard_rest/1`.

## Configuration

### Read configuration at runtime, not into module attributes

A module attribute is evaluated at compile time. `@base_url Application.get_env(:my_app, :base_url)` reads the value during compilation, triggers a compiler warning, and ignores `config/runtime.exs`. Read configuration inside the function that needs it. When the value must be known at compile time, use `Application.compile_env/3`, which the compiler tracks.

## Naming

- Modules are `CamelCase`, with acronyms kept upper case: `MyApp.HTTPClient` in `lib/my_app/http_client.ex`. Functions, variables, atoms, and file names are `snake_case`.
- Put every module under the top-level namespace of its own application or library: `MyApp.RateLimiter`, not `RateLimiter`, and not `Plug.Auth` in a package named `:plug_auth`. The VM loads one module per name, so packages that define the same module cannot be used together. Protocol implementations and `Mix.Tasks.*` are the exceptions.
- A function that returns a boolean ends in `?`: `valid?/1`, `admin?/1`. The `is_` prefix is only for guards, such as one defined with `defguard is_admin(user)`.
- `get` returns a value or a default (often `nil`), `fetch` returns `{:ok, value}` or `:error`, and `fetch!` raises.
- `size` means the operation is constant time (`map_size/1`, `byte_size/1`). `length` means it walks the data (`length/1`, `String.length/1`). Name your own functions the same way.
- Give ignored values a descriptive name with a leading underscore (`_reason`, `_opts`) when it tells the reader what is being ignored.
- Name variables after the domain (`order`, `line_item`, `refund`), not `data`, `item`, `res`, or `x`.

## Readability

### Comments explain why; documentation goes in `@moduledoc` and `@doc`

Delete comments that restate the code: `# Get the current time`, `# Check if user is over the limit`, or `# Unknown event type` above a clause whose pattern already says so. Keep comments that explain a reason the code cannot show.

Document modules and public functions with `@moduledoc` and `@doc`, not with comments above them. Include `## Examples` that work as doctests. Mark internal modules `@moduledoc false`. Do not put `@doc` on `defp`; the compiler discards it and warns. Place `@doc` and `@spec` directly above the `def`, without a blank line.

```elixir
# Instead of
# Imports a single user. Options: :notify - send a welcome email
def import_user(params, opts \\ []) do
# write
@doc """
Imports a single user.

## Options

  * `:notify` - sends a welcome email after the insert. Defaults to `false`.
"""
def import_user(params, opts \\ []) do
```

Name magic numbers with module attributes: `@session_ttl :timer.hours(24)`.

### Keep functions short and at one level of detail

A public function should read as a short sequence of named steps, with the details in private functions below it. When a `case`, `if`, or `with` appears inside another one, move the inner one into a named private function. Put public functions before the private helpers they call.

### Write pipelines that start with a value and read top to bottom

- Start a pipeline with a variable or literal, then one transformation per line.
- Do not pipe a single step: write `String.trim(name)`, not `name |> String.trim()`.
- Do not pipe into an anonymous function call (`|> (fn x -> ... end).()`). Break the pipeline and name the intermediate value, or use `then/2`.

### Use captures for one-call lambdas and `fn` for anything longer

`Enum.map(names, &String.trim/1)` and `Enum.map(users, & &1.id)` are clearer than the `fn` equivalents. When the body does more than one call or would need `&2`, write `fn` with named arguments.

## Before you finish

If you can run shell commands and Elixir is installed, do the steps below. Skip any step the user or the project's instructions tell you not to do; those instructions take precedence over this list.

1. Run `mix format path/to/file.ex` on the files you wrote or changed. It also works outside a Mix project.
2. Compile, and fix every warning in the code you wrote or changed, including unused variables and type warnings. Use `mix compile` in a Mix project. For a standalone file, run `elixir path/to/file.ex`, which compiles it in memory and leaves no `.beam` files behind.
3. If the project has Credo, run `mix credo --strict` and fix what it reports in the code you wrote or changed.
4. If the project has tests, run them.
