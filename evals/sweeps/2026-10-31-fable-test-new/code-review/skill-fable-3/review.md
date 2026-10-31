# Review: `Accounts.UserImporter`

The module has two bugs that make it misbehave in production, and a third that
makes it unsafe to expose to untrusted input. The age cap on lines 15 to 17
never applies, because the rebinding inside `if` does not escape the block. The
welcome email crashes every time, because `user[:name]` on a struct raises, and
the crash is hidden inside a bare `spawn`. And `String.to_atom(params["role"])`
lets whoever controls the input exhaust the atom table and crash the node.
Around those, the function hand-builds what Ecto changesets already do, swallows
every error as `{:error, :invalid}`, and changes its return shape based on an
option.

## Findings

Each finding names the rule from the skill, quotes the line, and shows the fix.
The improved module at the end applies all of them.

### 1. `String.to_atom/1` on external input

Rule: Convert external strings to atoms with explicit clauses.

```elixir
role = String.to_atom(params["role"])
```

Atoms are never garbage-collected and the VM (virtual machine) has a fixed atom
limit, so any input source that controls `"role"` can crash the node. The call
also sits outside the `try`, so a record with no `"role"` key raises
`ArgumentError` out of `import_user/2` instead of returning an error. Fix: let
`cast/3` on an `Ecto.Enum` field reject anything that is not one of the declared
values. If the schema stores `role` as a plain string, write
`defp parse_role("admin"), do: {:ok, :admin}` clauses with a final
`defp parse_role(other), do: {:error, {:unknown_role, other}}`.

### 2. `rescue _ ->` around the whole function

Rule: Return `{:ok, value}` or `{:error, reason}` for expected failures; raise
only for bugs.

```elixir
rescue
  _ -> {:error, :invalid}
```

The `try` exists to turn `String.to_integer/1` and `String.downcase/1` on bad
input into a tuple. It also catches bugs in the body, such as the `user[:name]`
crash below, and the constraint error `Repo.insert/1` raises when no
`unique_constraint/3` is declared. Fix: use the non-raising facility. `cast/3`
parses `"age"` into an integer and records an error when it cannot, and the
changeset carries the unique constraint. No `try` remains.

### 3. Rebinding `age` inside `if` does not escape

Rule: Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a
block does not escape it.

```elixir
if age > 120 do
  age = 120
end
```

The outer `age` keeps its value, the compiler warns that the inner one is
unused, and the cap never applies. Fix: `age = min(age, 120)`, or in the
changeset `update_change(:age, &min(&1, @max_age))`. I kept the cap because
that is what the code tried to do. If I owned the data I would reject the record
with `validate_number(:age, less_than_or_equal_to: 120)` instead, because an age
over 120 is a bad record, not a value to correct.

### 4. Single-step pipeline

Rule: Do not pipe a single step.

```elixir
email = params["email"] |> String.downcase()
```

Fix: `String.downcase(params["email"])`. In the improved module this becomes
`update_change(:email, &String.downcase/1)`, which also skips the call when the
field failed to cast.

### 5. `&&` on boolean operands

Rule: Use `and`, `or`, `not` when the operands are booleans.

```elixir
if is_binary(email) && age >= 18 do
```

Both sides are booleans, so `and` documents and checks that. The check is also
dead: `String.downcase/1` on the line above already raised for a non-binary.
Fix: `validate_required([:email, ...])` and
`validate_number(:age, greater_than_or_equal_to: @min_age)` replace the
condition.

### 6. Struct built from params and inserted without a changeset

Rule (ecto-phoenix reference): Validate input with changesets.

```elixir
user = %User{email: email, age: age, role: role, nickname: nickname}
...
case Repo.insert(user) do
```

Ecto inserts the struct as given, so nothing is validated and a constraint
violation raises. Fix:

```elixir
%User{}
|> cast(params, [:email, :age, :role, :nickname])
|> validate_required([:email, :age, :role])
|> ...
|> Repo.insert()
```

### 7. Lookup before insert instead of `unique_constraint/3`

Rule (ecto-phoenix reference): Declare database constraints in the changeset so
a violation returns `{:error, changeset}` instead of raising. The skill names
this exact shape as a finding.

```elixir
if Repo.get_by(User, email: email) == nil do
```

Two concurrent imports of the same address both pass the lookup, and the second
insert raises `Ecto.ConstraintError`, which the `rescue _` then reports as
`:invalid`. Fix: `unique_constraint(:email)` in the changeset, with a unique
index on `users.email`.

### 8. Catch-all `_ ->` on `Repo.insert/1`

Rule: Match every expected shape and let unexpected ones crash.

```elixir
_ ->
  {:error, :insert_failed}
```

`Repo.insert/1` returns `{:error, changeset}`, and the changeset says which
field failed. Fix: match `{:error, changeset}` and pass it through. In the
improved module the one-step `with` does that without a clause.

### 9. `{:error, :invalid}` for three different causes

Rule: Parse external data into structs where it enters the system, and when the
caller needs to know which field is missing or invalid, report it per field.

```elixir
{:error, :invalid}
```

A missing email, an under-age user, a duplicate address and a crash all come
back as the same atom, so a CSV import cannot tell the operator which row failed
why. Fix: return `{:error, %Ecto.Changeset{}}`, which carries one error per
field.

### 10. Overlapping boolean options

Rule: Use one atom-valued field or option instead of overlapping booleans. The
skill's own example is `import_user(params, notify: true, silent: false)`.

```elixir
if opts[:notify] && !opts[:silent] do
```

`silent: true` overrides `notify: true`, so one option exists only to cancel
the other. Fix: keep `:notify` alone, validate it with
`Keyword.validate!(opts, notify: false)`, and document it under `## Options`.

### 11. An option changes the return shape

Rule: Give each function one return shape.

```elixir
if opts[:return_id], do: user.id, else: {:ok, user}
```

With `return_id: true` the success path returns a bare integer while every
failure path returns a tuple, so a caller cannot pattern match the result. Fix:
always return `{:ok, user}` and let the caller read `user.id`.

### 12. Nested `if` inside `if` inside `case` inside `try`

Rules: Keep functions short and at one level of detail; Chain fallible steps
with `with`.

The body nests five constructs deep. Fix: one public function that reads as a
sequence of named steps, with a `changeset/1` helper that holds the validation
and a `send_welcome/1` helper for the side effect.

### 13. Bare `spawn/1` for the welcome email

Rule (processes reference): Supervise every long-lived process; fire-and-forget
work goes through `Task.Supervisor.start_child/2`.

```elixir
spawn(fn -> Mailer.deliver(welcome_email(user)) end)
```

A bare `spawn` is invisible to the supervision tree and to tools such as
Observer, and its crash is only logged, which is why finding 15 went unnoticed.
The closure also copies the whole `user` struct into the new process when only
the rendered email is needed. Fix:

```elixir
email = welcome_email(user)
Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
```

This needs `{Task.Supervisor, name: Accounts.TaskSupervisor}` in the
application's children list.

### 14. Comments that restate the code, and documentation in comments

Rule: Comments explain why; documentation goes in `@moduledoc` and `@doc`.

```elixir
# This module imports users from an external CSV/JSON source
...
# Import a single user from the given params
...
# Get the role from params
...
# send the email
```

Fix: `@moduledoc` and `@doc` with an `## Options` section, and delete the three
comments that restate the code. The one comment worth keeping is the reason the
address is lowercased, since the code cannot show it.

### 15. `Access` on a struct

Rule: Read required keys with `map.key` or a pattern; structs do not implement
`Access`.

```elixir
name = user[:name] || "there"
```

`%User{}` is a struct, so this raises `UndefinedFunctionError` on every
delivery. The struct built on line 22 also has no `:name` field; the display
name the code sets is `nickname`, which is always present because it defaults
to the email. Fix: `user.nickname`.

### 16. Piping into an anonymous function call

Rule: Do not pipe into an anonymous function call.

```elixir
greeting = "Hi " <> name <> ", welcome!"
greeting |> (fn text -> text <> " Enjoy your account." end).()
```

The binding `greeting` is used once and the lambda appends a literal. Fix: one
interpolated string.

## Improved code

Assumptions: `User` is an Ecto schema with `email` and `nickname` as `:string`,
`age` as `:integer`, `role` as `Ecto.Enum` with the accepted values, a `@type t`,
and a unique index on `email`. `Accounts.TaskSupervisor` is started in the
application's supervision tree. `Mailer` is left as the module the original
referenced.

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.

  Each record arrives as a string-keyed map. The importer normalizes it,
  validates it through a changeset, inserts it, and optionally sends a
  welcome email.
  """

  import Ecto.Changeset

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from a string-keyed map of params.

  Returns `{:ok, %User{}}` or `{:error, %Ecto.Changeset{}}`. The changeset
  carries one error per missing or invalid field, and an error on `:email`
  when the address is already taken.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, user} <- Repo.insert(changeset(params)) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  defp changeset(params) do
    %User{}
    |> cast(params, [:email, :age, :role, :nickname])
    |> validate_required([:email, :age, :role])
    # The provider lowercases addresses before its uniqueness check, so match it here
    |> update_change(:email, &String.downcase/1)
    |> update_change(:age, &min(&1, @max_age))
    |> validate_number(:age, greater_than_or_equal_to: @min_age)
    |> put_default_nickname()
    |> unique_constraint(:email)
  end

  defp put_default_nickname(changeset) do
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

## Verification

`mix format --check-formatted` passes on the improved module and the file
parses. A full compile was not run: the module imports `Ecto.Changeset`, which
needs a Mix project with Ecto as a dependency, and none exists here.
