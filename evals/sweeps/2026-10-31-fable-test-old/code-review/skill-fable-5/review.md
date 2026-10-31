# Review: `Accounts.UserImporter`

Reviewed against the idiomatic-elixir skill, including `references/processes.md` (the code calls `spawn/1`) and `references/ecto-phoenix.md` (the code calls `Repo`).

The module has two behaviour bugs that affect every call: the age cap never applies, and the welcome email crashes before it is sent. It also has a race on the email uniqueness check, an atom-exhaustion vector on `role`, and a `rescue` that turns every exception into the same `{:error, :invalid}`. The rest are readability and API-shape problems. Each finding below names the rule, quotes the line, and shows the fix. The improved module at the end applies all of them.

## Findings

### 1. Assigning inside `if` does not escape the block, so the age cap never applies

Rule: "Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it".

```elixir
if age > 120 do
  age = 120
end
```

The outer `age` keeps its parsed value, and the compiler warns that the inner `age` is unused. The cap has never worked. Because the code already rejects ages under 18, the improved version treats 120 the same way, as a validation bound rather than a silent clamp:

```elixir
|> validate_number(:age, greater_than_or_equal_to: @min_age, less_than_or_equal_to: @max_age)
```

If the intent really was to clamp, write `age = min(age, 120)` instead. Either way the assignment must produce a value, not rebind inside a block.

### 2. `user[:name]` raises because structs do not implement `Access`

Rule: "Read required keys with `map.key` or a pattern; keep `map[:key]` for optional keys". Structs do not implement `Access`, so `user[:name]` raises `UndefinedFunctionError`.

```elixir
name = user[:name] || "there"
```

`send_welcome/1` runs this inside a spawned process, so the crash is silent and no email is ever sent. The struct also has no `name` field; the field set earlier is `nickname`, which always holds a value because it defaults to the email. The fix reads the struct field directly:

```elixir
"Hi #{user.nickname}, welcome! Enjoy your account."
```

### 3. `String.to_atom/1` on external input can exhaust the atom table

Rule: "Convert external strings to atoms with explicit clauses".

```elixir
role = String.to_atom(params["role"])
```

Whoever controls the import source can create an unbounded number of atoms and crash the node. This line also sits outside the `try`, so a missing role raises `FunctionClauseError` out of the function instead of returning an error. The fix is to let the changeset cast the field with `Ecto.Enum`, which accepts only the declared values and returns a changeset error for anything else:

```elixir
|> cast(params, [:email, :age, :role, :nickname])
```

This assumes `Accounts.User` declares `field :role, Ecto.Enum, values: [...]`. If it does not, add that to the schema, or parse the role with explicit clauses (`defp parse_role("admin"), do: {:ok, :admin}`, with a final clause returning `{:error, {:unknown_role, other}}`).

### 4. Lookup before insert is a race; declare `unique_constraint/3` instead

Rule (ecto-phoenix reference): "Declare database constraints in the changeset (`unique_constraint/3` ...) so a violation returns `{:error, changeset}` instead of raising". The skill names this exact shape as a finding: "a lookup before an insert where the changeset rule names `unique_constraint/3`".

```elixir
if Repo.get_by(User, email: email) == nil do
  case Repo.insert(user) do
```

Two concurrent imports of the same email both pass the `get_by` check and the second insert raises on the database index. The fix removes the lookup and adds the constraint to the changeset:

```elixir
|> unique_constraint(:email)
```

### 5. Inserting a hand-built `%User{}` skips validation

Rule (ecto-phoenix reference): "A `%User{}` built from the params and passed to `Repo.insert/1` is the pattern to replace: Ecto inserts the struct as given, so nothing is validated".

```elixir
user = %User{email: email, age: age, role: role, nickname: nickname}
...
case Repo.insert(user) do
```

The improved version builds a changeset with `cast/3`, `validate_required/2`, `validate_number/3`, and `unique_constraint/3`. The integer parse, the type check on email, the age bounds, and the uniqueness check all become changeset errors the caller can inspect.

### 6. `rescue _ ->` around the whole function hides every bug as `:invalid`

Rule: "Do not wrap a raising call in `try/rescue` to get a tuple ... never `rescue _ ->` or `rescue e ->` around a whole function".

```elixir
rescue
  _ -> {:error, :invalid}
```

A missing `age` key, a non-numeric age, a database connection failure, and a typo in this module all come back as the same `{:error, :invalid}`. The changeset cast handles the parsing failures as errors, so the improved version has no `try` at all.

### 7. `_ ->` after `{:ok, user}` collapses every other return into `:insert_failed`

Rule: "Match every expected shape and let unexpected ones crash".

```elixir
_ ->
  {:error, :insert_failed}
```

`Repo.insert/1` returns `{:error, changeset}`, which carries the reason. The fix matches it and passes it through:

```elixir
{:error, _changeset} = error ->
  error
```

### 8. Four nested `if`/`case` levels in one public function

Rule: "Keep functions short and at one level of detail. When a `case`, `if`, or `with` appears inside another one, move the inner one into a named private function." Also "Branch with function clauses and guards before reaching for `if` or `cond`".

The body of `import_user/2` nests `try` > `if` > `if` > `case` > `if`. The improved version has one `case` on the insert, with the validation in `import_changeset/1` and the nickname default in `default_nickname/1`.

### 9. `opts[:return_id]` gives the function two return shapes

Rule: "Give each function one return shape. Options must not change what a function returns."

```elixir
if opts[:return_id], do: user.id, else: {:ok, user}
```

One mode returns a bare integer, the other a tuple, and the error paths always return tuples. The improved version always returns `{:ok, user}`; a caller that wants the id reads `user.id`. If a bare id is needed often, add a separate `import_user_id/2` rather than an option.

### 10. `notify: true, silent: false` are overlapping booleans

Rule: "Use one atom-valued field or option instead of overlapping booleans. Two booleans overlap when one overrides the other".

```elixir
if opts[:notify] && !opts[:silent] do
```

`silent` only exists to override `notify`. The improved version keeps `:notify` alone.

### 11. Options are neither validated nor documented

Rule: "Put optional settings in a keyword list as the last argument (`opts \\ []`), check them with `Keyword.validate!/2`, and document each one under `## Options` in `@doc`."

```elixir
def import_user(params, opts \\ []) do
```

A misspelled option such as `notfiy: true` is silently ignored today. The fix:

```elixir
opts = Keyword.validate!(opts, notify: false)
```

and an `## Options` section in `@doc`.

### 12. `spawn/1` for the welcome email is unsupervised and copies the whole user

Rule (processes reference): "Supervise every long-lived process ... A bare `spawn/1` or `Task.start/1` outside a supervisor has none of this", the table entry "Fire-and-forget work: `Task.Supervisor.start_child/2`", and "Send processes only the data they need ... all variables captured by an anonymous function passed to `spawn/1` are copied".

```elixir
spawn(fn -> Mailer.deliver(welcome_email(user)) end)
```

The crash from finding 2 goes unnoticed because nothing links or logs it. The fix builds the email in the calling process and hands only that to a supervised task:

```elixir
email = welcome_email(user)
Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
```

`Accounts.TaskSupervisor` must be started in the application's supervision tree as `{Task.Supervisor, name: Accounts.TaskSupervisor}`.

### 13. `&&` where both operands are booleans

Rule: "Use `and`, `or`, `not` when the operands are booleans".

```elixir
if is_binary(email) && age >= 18 do
```

Would be `is_binary(email) and age >= 18`. In the improved version the check moves into the changeset, so the line disappears.

### 14. Single-step pipe

Rule: "Do not pipe a single step: write `String.trim(name)`, not `name |> String.trim()`."

```elixir
email = params["email"] |> String.downcase()
```

In the improved version the downcase becomes a changeset step, `update_change(:email, &String.downcase/1)`, which also stops a missing email from raising `FunctionClauseError` before validation runs. The comment explaining why the address is lowercased is kept, because it gives a reason the code cannot show.

### 15. Pipe into an anonymous function

Rule: "Do not pipe into an anonymous function call (`|> (fn x -> ... end).()`)."

```elixir
greeting |> (fn text -> text <> " Enjoy your account." end).()
```

The two concatenations are one interpolated string:

```elixir
"Hi #{user.nickname}, welcome! Enjoy your account."
```

### 16. Comments restate the code; no `@moduledoc`, `@doc`, or `@spec`

Rule: "Comments explain why; documentation goes in `@moduledoc` and `@doc`. Delete comments that restate the code."

```elixir
# This module imports users from an external CSV/JSON source
...
# Import a single user from the given params
...
# Get the role from params
...
# send the email
```

The first two become `@moduledoc` and `@doc`; the other two are deleted. The public function gets a `@spec`.

### 17. `120` and `18` are magic numbers

Rule: "Name magic numbers with module attributes".

```elixir
if age > 120 do
...
if is_binary(email) && age >= 18 do
```

The improved version names them `@min_age` and `@max_age`.

### 18. `Mailer` is not under the application namespace

Rule: "Put every module under the top-level namespace of its own application or library".

```elixir
spawn(fn -> Mailer.deliver(welcome_email(user)) end)
```

The improved version aliases `Accounts.Mailer`, on the assumption that the mailer belongs to this application. If `Mailer` is a third-party module, drop the alias and keep the bare name.

## Notes on the improved version

- `Keyword.validate!/2` raises on unknown options. That is the intended behaviour: a misspelled option is a bug in the caller.
- `Repo.insert/1` is the only fallible step, and the body builds the result, so the function uses `case` rather than a one-step `with`, as the rule on `with` requires.
- `default_nickname/1` reads the already-downcased email through `get_field/2`, so the default matches what is stored.
- A `role` value outside the `Ecto.Enum` list and a non-integer `age` both surface as changeset errors rather than exceptions.
- The file passes `mix format --check-formatted` and parses. It was not compiled, because Ecto and `Accounts.User` are not available in the review directory.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  import Ecto.Changeset

  alias Accounts.Mailer
  alias Accounts.Repo
  alias Accounts.User

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from string-keyed `params`.

  Returns `{:ok, user}` on success and `{:error, changeset}` when the params
  are invalid or the email is already taken.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.

  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    case Repo.insert(import_changeset(params)) do
      {:ok, user} ->
        if opts[:notify], do: send_welcome(user)
        {:ok, user}

      {:error, _changeset} = error ->
        error
    end
  end

  defp import_changeset(params) do
    %User{}
    |> cast(params, [:email, :age, :role, :nickname])
    |> validate_required([:email, :age, :role])
    # The provider lowercases addresses before its uniqueness check, so match it here
    |> update_change(:email, &String.downcase/1)
    |> validate_number(:age, greater_than_or_equal_to: @min_age, less_than_or_equal_to: @max_age)
    |> default_nickname()
    |> unique_constraint(:email)
  end

  defp default_nickname(changeset) do
    case get_field(changeset, :nickname) do
      nil -> put_change(changeset, :nickname, get_field(changeset, :email))
      _nickname -> changeset
    end
  end

  defp send_welcome(user) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```
