---
name: idiomatic-elixir
description: Rules for idiomatic Elixir that correct the common mistakes in generated code, covering pattern matching, error handling, collections, naming, readability, and OTP processes. Use whenever writing, editing, refactoring, or reviewing Elixir code (.ex or .exs files, Mix projects), including Phoenix, Ecto, ExUnit tests, GenServers, macros, and Hex libraries.
license: Apache-2.0
---

# Idiomatic Elixir

Readability rules carry the same weight as correctness rules.

## How to use this skill

- **Reference files:** besides following the rules below, read every reference file whose trigger appears in the code or the task, before you write code and, in a review, before you list findings:

  | If the code or task involves | Read |
  | --- | --- |
  | `GenServer`, `Agent`, `Task`, `spawn`, `send`, `:ets`, a supervisor, or shared state | `references/processes.md` |
  | a Hex package, or a public module API other code depends on | `references/library-design.md` |
  | `defmacro`, `quote`, `__using__`, `use` of your own module, or `Module.concat` | `references/macros.md` |
  | a test to write, change, run or review, whatever the task is otherwise about: `ExUnit`, `test/`, `mix test`, `assert` | `references/ex_unit.md` |
  | `Repo`, `Ecto`, schemas, migrations, Phoenix controllers, contexts, or LiveViews | `references/ecto-phoenix.md` |

- **When to load it:** read this file before the first line of code. A review afterwards reports the patterns the rules describe; a design no rule names, such as a hand-built logger handler where `capture_log/2` would do, goes unreported, while code written with the skill loaded does not take that shape.
- **Formatting:** formatting is part of writing a file, not a pass over the project at the end. The step after you finish a file, before you write the next one or run the tests, is `mix format --check-formatted path/to/file.ex` on that file alone. When it fails, format the file and read the lines the formatter moved. A `do:` body moved onto its own line or a literal argument spread over several lines is a line to rewrite under the rules below (a block, a named argument), not to accept, and rewriting it now keeps the next file from repeating the shape; a wrap after `=` or before `|>` is the formatter's own and stays. A file you come back to is checked again when you leave it. When several agents write files, each formats its own.
- **Reviewing code:** report a finding where the code contains the pattern a rule describes, and where the code builds by hand what a rule names a facility for, such as a lookup before an insert where the changeset rule names `unique_constraint/3`. For each finding, name the rule, quote the line, and show the fix. If you also write an improved version, it must apply every finding you reported.
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

A keyword list has no dot access: read a key it must hold with `Keyword.fetch!/2`, as in `Keyword.fetch!(Mix.Project.config(), :deps)`, and keep `opts[:key]` for an option that has a default.

A pattern is the way to read a value where the match also decides something: a function head or a `case` clause, where a failed match sends the value to the next clause, or the result of a call, where `{:ok, %Req.Response{} = response} = Req.get(req)` asserts the shape at the point it arrives. A pattern in a body that pulls one atom key or struct field out of a value the function already holds, with no literal and no guard, is dot access written long. Keep such a pattern when it binds two or more fields the body uses together, matches a literal, or carries a guard.

```elixir
# Instead of
%{default: default} = config
{:ok, %{default: default, limits: Map.get(config, :users, %{})}}
# write
{:ok, %{default: config.default, limits: Map.get(config, :users, %{})}}
```

A chain such as `request.user.profile.name` reads a nested required field in one expression; binding `user` and `profile` on the way earns its lines only when a value is reused or has a name the domain uses. Each step of the chain assumes the previous value is a map that holds the field, so when a step may be `nil` the chain raises there: handle an optional step with a `case` on it, or read `get_in(request.user.profile.name)` (Elixir 1.17 or later) when `nil` is the answer you want. `get_in/1` passes a `nil` step through as `nil`; a key that is absent still raises `KeyError`.

```elixir
# Instead of
user = request.user
profile = user.profile
name = profile.name
# write
name = request.user.profile.name
# or, when a profile is optional and nil is the right answer
name = get_in(request.user.profile.name)
```

`map[:key]` and `Map.get/2` return the same `nil` for an absent key and for a key set to `nil`. When those two need different handling, `Map.fetch/2` returns `:error` for the absent key and `{:ok, nil}` for the other.

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

The same goes for `elem/2` on a tuple whose shape is known: `fn {id, _pid, _type, _modules} -> id end` says what `Supervisor.which_children/1` returns, `&elem(&1, 0)` does not.

When the input set is open by design (event types from an external system, messages from other processes), end with a clause that binds and names what it catches: `defp parse_event(type, _payload), do: {:error, {:unsupported_event, type}}`. Make sure that clause can only receive what its error names. If one set of clauses both selects the event type and matches its fields, a known type with a missing field falls through to "unsupported event". Select the type in one function and validate the fields in another.

### In multi-clause functions, bind in the head only what patterns and guards use

A head binds what selects its clause: a value matched against a literal, a value a guard reads, or a key whose presence selects, because another clause catches the input that lacks it. A struct always has its fields, so a struct field selects only through a literal, a nested pattern that must match, or a guard. A field no pattern or guard uses makes the reader scan every head to find what selects when the same field is bound in every clause of a function with three or more clauses, or when it is bound in a head whose pattern `mix format` spreads over several lines; a function whose clauses each bind a different body-only field is not this shape. Take the value whole with `= order` and read `order.total` in the body. A head that `mix format` wraps only to move a long guard onto its own line is fine as wrapped; a single-clause function may destructure in its head; and the `= order` alias beside a pattern is not a bound field.

```elixir
# Instead of
def label(%Order{id: id, customer: customer, total: total, status: :paid}) do
  "order #{id} for #{customer.name}: paid #{total}"
end

def label(%Order{id: id, customer: customer, total: total, status: :refunded}) do
  "order #{id} for #{customer.name}: refunded #{total}"
end

def label(%Order{id: id, customer: customer, total: total, status: status})
    when status in [:pending, :shipped] do
  "order #{id} for #{customer.name}: #{status}, #{total} due"
end
# write
def label(%Order{status: :paid} = order) do
  "order #{order.id} for #{order.customer.name}: paid #{order.total}"
end

def label(%Order{status: :refunded} = order) do
  "order #{order.id} for #{order.customer.name}: refunded #{order.total}"
end

def label(%Order{status: status} = order) when status in [:pending, :shipped] do
  "order #{order.id} for #{order.customer.name}: #{status}, #{order.total} due"
end
```

A pattern that selects never moves from the head into the body. A failed head pattern lets the next clause run; a failed body match raises `MatchError`, and a missing field read with dot access raises `KeyError`. So the first `dispatch/1` below matches a `:created` command that has no `:id` and raises on `command.id`, where the second sends that command to the clause that answers `{:error, :missing_id}`.

```elixir
# Instead of
def dispatch(%{type: :created} = command), do: create(command.id)
def dispatch(_command), do: {:error, :unsupported_command}
# write
def dispatch(%{type: :created, id: id}), do: create(id)
def dispatch(%{type: :created}), do: {:error, :missing_id}
def dispatch(_command), do: {:error, :unsupported_command}
```

A function that parses string-keyed input matches the keys it requires in its head, `def parse(%{"id" => id, "type" => type, "data" => data} = payload)`, with `def parse(_payload), do: {:error, :invalid_payload}` below it: those keys select the clause by their presence, so they belong in the head even when the guard reads none of them. The clause that catches the rest names only what it can know, `:invalid_payload`, never a cause it cannot tell apart; selecting the type and validating its fields stay separate functions, as the rule above says.

### Update structs with `%{struct | field: value}`

The update syntax raises if the field does not exist. `Map.put/3` with a misspelled key silently produces a broken struct. In `defstruct`, list a field whose default is `nil` as a bare atom, `defstruct [:items, :discount]`, not `discount: nil`; a keyword entry is for a real default, such as `items: %{}`.

### Convert external strings to atoms with explicit clauses

Atoms are never garbage-collected and the VM (virtual machine) has a fixed atom limit, 1,048,576 by default. `String.to_atom/1` on input lets anyone who controls the input exhaust it and crash the node. The same applies to `keys: :atoms` in JSON decoders. List the accepted values instead:

```elixir
defp parse_status("active"), do: {:ok, :active}
defp parse_status("suspended"), do: {:ok, :suspended}
defp parse_status(other), do: {:error, {:unknown_status, other}}
```

`String.to_existing_atom/1` is acceptable only when every valid atom appears literally in the same module, for example in a function that lists them. Atoms that appear only in a module attribute no function reads, or only in code that runs at compile time, are not in the compiled module and may not exist at runtime.

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

A `with` chains two or more `<-` steps. One step is a `with` only when its body cannot fail and there is no `else`, so the `with` does nothing but pass the error through; any other one-step `with` is a `case`. A large `else` block that maps errors back to steps is hard to follow and breaks when two steps fail with the same shape. Give each step a private function that returns `{:ok, value}` or `{:error, reason}`, and let `with` pass the error through unchanged.

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

Count the `<-` clauses before writing `with`. With one, the `with` earns its place only as a pass-through: `with :ok <- apply_update(doc, update), do: {:ok, doc}` says that the error comes back unchanged. A `case` whose error clause is `{:error, _reason} = error -> error` is the same pass-through spelled out over four lines; write it as the `with`. The moment the one step needs more, the shape changes. An `else` that maps the one error is a `case`, which shows both outcomes in one place. A body that calls another function that can fail and works on its result makes that call the second step, chained with a second `<-` instead of a nested `case`. A body that is one call whose `{:ok, value}` or `{:error, reason}` goes out as the function's own result, the recursive `parse_rows(rest, [order | orders])` of a hand-written loop, is a tail call, not a second step, and the one-step `with` stays.

```elixir
# Instead of
def build(rows) do
  case parse_orders(rows) do
    {:ok, orders} -> {:ok, summarize(orders)}
    {:error, _reason} = error -> error
  end
end
# write
def build(rows) do
  with {:ok, orders} <- parse_orders(rows) do
    {:ok, summarize(orders)}
  end
end

# Instead of
with {:ok, contents} <- File.read(path) do
  {:ok, contents}
else
  {:error, _reason} -> {:error, :badfile}
end
# write
case File.read(path) do
  {:ok, contents} -> {:ok, contents}
  {:error, _reason} -> {:error, :badfile}
end

# Instead of
with {:ok, text} <- string_field(row, "amount") do
  case Decimal.parse(text) do
    {amount, ""} -> {:ok, Decimal.round(amount, 2)}
    {_amount, _rest} -> {:error, {:invalid_field, "amount"}}
    :error -> {:error, {:invalid_field, "amount"}}
  end
end
# write
with {:ok, text} <- string_field(row, "amount"),
     {:ok, amount} <- parse_amount(text) do
  {:ok, Decimal.round(amount, 2)}
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
| `Enum.reduce(orders, %{}, fn order, acc -> Map.update(acc, order.customer_id, [order], &[order \| &1]) end)` | `Enum.group_by(orders, & &1.customer_id)`, then `Map.new/2` over the groups to summarize each; a `reduce` that reads and writes one key per element is these two written by hand |
| `Enum.into(pairs, %{})` | `Map.new(pairs)` |
| `Enum.map(items, &f/1) \|> Enum.join(", ")` | `Enum.map_join(items, ", ", &f/1)` |
| `Enum.reduce(items, 0, &(&1.amount + &2))` | `Enum.sum_by(items, & &1.amount)` (Elixir 1.18+) |
| `Enum.filter(items, &f/1) \|> Enum.count()` | `Enum.count(items, &f/1)` |
| `Enum.group_by(items, &k/1) \|> Map.new(fn {k, v} -> {k, length(v)} end)` | `Enum.frequencies_by(items, &k/1)` |
| `Enum.sort(items) \|> Enum.reverse()` | `Enum.sort(items, :desc)` |
| `Enum.find(items, &f/1) != nil` | `Enum.any?(items, &f/1)` |
| `List.keyfind(pairs, key, 0) == nil` | `not List.keymember?(pairs, key, 0)` |
| `for path <- paths, File.read!(path) =~ ~r/Yex/, do: path` | `Enum.filter(paths, &(File.read!(&1) =~ ~r/Yex/))` |
| `if Map.has_key?(map, k), do: Map.get(map, k)` | `case Map.fetch(map, k) do` |
| `Map.put(map, k, f.(Map.get(map, k)))` | `Map.update!(map, k, f)` when `k` must exist; `Map.update(map, k, initial, f)` when it may be missing |

### Treat lists as linked lists

`length/1` and `Enum.at/2` walk the list. `acc ++ [item]` copies `acc` every time, so a loop that appends is quadratic. Build lists with `Enum.map/2` or a comprehension, or prepend with `[item | acc]` and reverse once at the end. Check for empty lists with `list == []` or a `[]` / `[_ | _]` pattern, not `length(list) == 0`. When you need an element's position, use `Enum.with_index/2` or `Enum.zip/2` instead of indexing in a loop. `list[0]` does not index a list: `Access` treats a list as a keyword list and raises `ArgumentError` for an integer key. Use a pattern, or `Enum.at/2` when you need one position.

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

The same holds for work. A module attribute holds a literal or a value built from literals, `@window_ms :timer.minutes(1)` or `@fixtures Path.expand("fixtures", __DIR__)`. One that reads the file system, the project or the environment, `@sources Path.wildcard("lib/**/*.ex")` or `@deps Mix.Project.config()[:deps]`, fixes its answer when the file compiles and hides a call behind a constant's name; write a function and call it where the value is used.

## Naming

- Modules are `CamelCase`, with acronyms kept upper case: `MyApp.HTTPClient` in `lib/my_app/http_client.ex`. Functions, variables, atoms, and file names are `snake_case`.
- Put every module under the top-level namespace of its own application or library: `MyApp.RateLimiter`, not `RateLimiter`, and not `Plug.Auth` in a package named `:plug_auth`. The VM loads one module per name, so packages that define the same module cannot be used together. Protocol implementations and `Mix.Tasks.*` are the exceptions.
- A function that returns a boolean ends in `?`: `valid?/1`, `admin?/1`. The `is_` prefix is only for guards, such as one defined with `defguard is_admin(user)`.
- `get` returns a value or a default (often `nil`), `fetch` returns `{:ok, value}` or `:error`, and `fetch!` raises. A function that looks a key up and also checks the value, returning `{:error, reason}`, is not a `fetch`: name it by its job, such as `string_field/2` or `parse_amount/1`.
- `size` means the operation is constant time (`map_size/1`, `byte_size/1`). `length` means it walks the data (`length/1`, `String.length/1`). Name your own functions the same way.
- Give ignored values a descriptive name with a leading underscore (`_reason`, `_opts`) when it tells the reader what is being ignored.
- Name variables after the domain (`order`, `line_item`, `refund`), not `data`, `item`, `res`, or `x`. A variable may carry the name of the external key it holds, as in `%{"data" => data}`, since the payload chose that name.

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

### Build a multi-line argument under a name before the call

Unless a call's result is bound to a name, each of its arguments is a name, a short literal, or a trailing keyword list: a map or struct that would span several lines is built first under a name that says what it is, one field per line, with a blank line between multi-line statements. That holds whether the result is passed on, matched against, nested in another call or discarded. The reader then sees the steps in order: build the parts, build the whole, make the call. A keyword list that is the call's last argument stays inline, one option per line, the way `config :my_app, key: value` and `Application.put_env/3` are written everywhere; a keyword list in any other position, or one holding a multi-line map, gets a name. A call whose result is bound to a name may take its options inline, as `formatter` does below; a call with its own options nested inside a literal becomes a name too. An assertion is a call like any other: when `mix format` spreads the expected map of `assert_issue(run("fixture.ex"), %{line_no: 4, trigger: "..."})` over several lines, bind it first as `expected = %{...}` and assert on the name. A list, map or keyword literal of more than six elements goes one element per line wherever it stands, a module attribute included; `mix format` keeps that layout when a line break follows the opening bracket. A shorter literal that fits its line stays on one line.

```elixir
# Instead of
:ok =
  :logger.add_handler(@handler, :logger_std_h, %{
    level: :all,
    config: %{type: {:device, device}},
    formatter:
      Logger.Formatter.new(
        format: "$level $metadata$message\n",
        metadata: :all,
        colors: [enabled: false]
      )
  })
# write
formatter =
  Logger.Formatter.new(
    format: "$level $metadata$message\n",
    metadata: :all,
    colors: [enabled: false]
  )

handler_config = %{
  level: :all,
  config: %{type: {:device, device}},
  formatter: formatter
}

:ok = :logger.add_handler(@handler, :logger_std_h, handler_config)
```

### Use `do:` for a one-expression body and `do ... end` for anything else

Use `do:` for a body of one expression with no body of its own inside it: a literal, a tuple, a field read, a comparison, or a call, nested or not. A body with several steps, a `case`, `with`, `if` or `receive`, a comment, or a `fn` gets `do ... end`, however short it is: `defp draws, do: Enum.map(1..5, fn _draw -> :rand.uniform() end)` fits on the line and is still a block, because the `fn` is a second body and two bodies do not share a line. A capture that carries a call with arguments of its own, `&match?({:unquote, _, _}, &1)` or `&Map.get(&1, key)`, is a second body too; `&part/1` and `& &1.id` are not. A function may mix the forms: a short clause on `do:`, a clause that needs a block as a block, each block clause set apart with a blank line. A `do:` body belongs on the head's line: when `mix format` moves it onto a line of its own, the body is too long for `do:`, so write a block or move part of the body into a helper. The one wrap to keep is a head that `mix format` breaks after a long guard, with `do:` on the next line. `if ..., do: ..., else: ...` stays on one line when one branch is a name or a literal, the fallback, and the other does the work, as in `if String.valid?(term), do: redact(term, config), else: term`; when both branches call something, write `do ... end` with a branch per line, even though the one-line form fits, and a branch `mix format` moves onto its own line gets `do ... end` as well. A `for` always takes `do ... end`: its generators and filters already fill the head.

```elixir
# Instead of
def decode(nil), do: {:error, :missing_input}
def decode(value), do: value |> Decoder.decode() |> normalize_result()

defp draws, do: Enum.map(1..5, fn _draw -> :rand.uniform() end)

def message(%__MODULE__{reason: {:unknown_type, type}}),
  do: "unknown event type #{inspect(type)}, expected one of the documented types"

if enabled?(), do: {:ok, with_url(config)}, else: refuse_start(type, config)

names = for ":" <> name <- parts, do: name
# write
def decode(nil), do: {:error, :missing_input}

def decode(value) do
  value
  |> Decoder.decode()
  |> normalize_result()
end

defp draws do
  Enum.map(1..5, fn _draw ->
    :rand.uniform()
  end)
end

def message(%__MODULE__{reason: {:unknown_type, type}}) do
  "unknown event type #{inspect(type)}, expected one of the documented types"
end

if enabled?() do
  {:ok, with_url(config)}
else
  refuse_start(type, config)
end

names =
  for ":" <> name <- parts do
    name
  end
```

### Break a `->` clause whose pattern and body together pass 70 characters

A clause of `case`, `cond`, `with ... else` or `receive` stays on one line while its pattern, the `->` and its body together fit in 70 characters, not counting indentation. Past that, the body goes on the line after the `->`: the reader then sees what the clause matches on one line and what it does on the next, instead of finding the `->` by eye inside a line that `mix format` leaves alone, since the formatter wraps only at 98 columns. Once one clause breaks, `mix format` moves every clause's body down and separates the clauses with a blank line; keep that layout, and do not pull the short clauses back onto one line. A `fn` passed as an argument follows the capture rule instead: when it binds names, its body goes on the line after the `->` whatever its length.

```elixir
# Instead of
defp value_end(string, offset, depth) do
  case string do
    <<_::binary-size(^offset)>> -> offset
    <<_::binary-size(^offset), byte, _::binary>> -> step(byte, string, offset, depth)
  end
end
# write
defp value_end(string, offset, depth) do
  case string do
    <<_::binary-size(^offset)>> ->
      offset

    <<_::binary-size(^offset), byte, _::binary>> ->
      step(byte, string, offset, depth)
  end
end
```

### Write pipelines that start with a value and read top to bottom

- Start a pipeline with the value being transformed, a variable or a literal, then one transformation per line. A pipeline never sits on one line, however short: two steps on one line, `sql |> String.split(~r/\W+/, trim: true) |> Enum.uniq()`, hide where one step ends and the next begins, so they go on three lines after `words =`, or become a nested call when there are only two. An argument that only selects a kind or a mode does not start a pipeline: `Exception.format(:error, error, stacktrace)`, not `:error |> Exception.format(error, stacktrace)`.
- Do not pipe a single step: write `String.trim(name)`, not `name |> String.trim()`.
- Do not pipe into an anonymous function call (`|> (fn x -> ... end).()`). Break the pipeline and name the intermediate value, or use `then/2`.

```elixir
# Instead of
words = sql |> String.split(~r/\W+/, trim: true) |> Enum.uniq()

defp names(modules), do: modules |> Enum.sort() |> Enum.join(", ")
# write
words =
  sql
  |> String.split(~r/\W+/, trim: true)
  |> Enum.uniq()

defp names(modules), do: Enum.join(Enum.sort(modules), ", ")
```

### Use captures for one-call lambdas and `fn` for anything longer

`Enum.map(names, &String.trim/1)` and `Enum.map(users, & &1.id)` are clearer than the `fn` equivalents, and so is a capture that uses `&1` and `&2` for one operator or one call, such as `&(&1 + &2)` or `&Decimal.add(&1.amount, &2)`, with `&1` and `&2` in that order and each used once. When the body does more than one call, would need `&3`, or passes `&2` before `&1` or the same placeholder twice, write `fn` with named arguments: the reader of `&table_issue(&2, &1, meta, &1)` has to work out which argument is the word and which the context, and `fn word, ctx -> table_issue(ctx, word, meta, word) end` tells them.

A `fn` that binds names takes the room its names earn: the body goes on the line after the `->`, and `end` closes it on a line of its own, the layout `mix format` keeps once it is written. A one-line `fn {name, kind} -> {name, root_view(doc, name, kind)} end` is a capture that could not be written, squeezed onto the head's line, and the reader parses the pattern and the body in one pass. A `fn -> now end` that binds nothing may stay on one line.

```elixir
# Instead of
Map.new(roots, fn {name, kind} -> {name, root_view(doc, name, kind)} end)
# write
Map.new(roots, fn {name, kind} ->
  {name, root_view(doc, name, kind)}
end)
```

### Open a module with `use`, `import`, `alias`, `require`, in that order

Right after `@moduledoc`, group each kind together, in that order, so what the module pulls in sits in the same place in every file.

```elixir
use GenServer

import Ecto.Query, only: [from: 2]

alias MyApp.Repo
alias MyApp.Orders.Order

require Logger
```

## Before you finish

If you can run shell commands and Elixir is installed, do the steps below. Skip any step the user or the project's instructions tell you not to do; those instructions take precedence over this list.

1. Run `mix format path/to/file.ex` on any changed file you have not formatted since its last edit (see "Formatting" under "How to use this skill"). It also works outside a Mix project.
2. Compile, and fix every warning in the code you wrote or changed, including unused variables and type warnings. Use `mix compile` in a Mix project. For a standalone file, run `elixir path/to/file.ex`, which compiles it in memory and leaves no `.beam` files behind.
3. If the project has Credo, run `mix credo --strict` and fix what it reports in the code you wrote or changed.
4. If the project has tests, run them. While you work on one module, `mix test test/my_app/orders_test.exs` runs only its tests, `mix test test/my_app/orders_test.exs:42` the one test at that line, and `mix test --failed` the tests that failed last time. Run the whole suite once more before you finish, since a change in one module can break a test in another.
