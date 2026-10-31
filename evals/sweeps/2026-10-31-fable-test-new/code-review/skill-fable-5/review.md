# Review of `Accounts.UserImporter`

Reviewed against the idiomatic-elixir skill (`SKILL.md`) plus its `processes.md`, `ecto-phoenix.md` and `library-design.md` references.

The module has three outright bugs: the age cap never applies, the welcome email can never be sent, and a duplicate email can slip past the pre-insert lookup. The rest is shape: hand-rolled validation where a changeset does the job, a `rescue _` that hides every cause behind `:invalid`, overlapping boolean options, and a function with two return shapes.

The improved version assumes two things about code outside this file. `User` declares `role` as an `Ecto.Enum` field, which is what the original's atom conversion implies; if it is a `:string` field, replace the cast with explicit `parse_role/1` clauses as the atom rule shows. The `users.email` column has a unique index, which `unique_constraint/3` needs, and `Accounts.TaskSupervisor` is started in the application's supervision tree.

## Findings

### 1. `if age > 120 do age = 120 end` never changes `age`

Rule: *Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it.*

```elixir
if age > 120 do
  age = 120
end
```

The inner `age` is local to the `if`; the outer `age` keeps its value and the compiler warns about an unused variable. Every age over 120 is inserted as given. Fix: assign the result, `age = min(age, 120)`, or in the changeset `update_change(:age, &min(&1, @max_age))`. The improved code does the latter and names the number with `@max_age`.

### 2. `user[:name]` raises on a struct, so no welcome email is ever delivered

Rule: *Read required keys with `map.key` or a pattern* ("Structs do not implement `Access`: `user[:name]` raises `UndefinedFunctionError`").

```elixir
name = user[:name] || "there"
```

`user` is a `%User{}`, so this raises inside the spawned process. The crash is invisible to the caller and the mail is never sent. The field this importer fills is `nickname`, which is always set (it falls back to the email), so the greeting reads `user.nickname` and the `|| "there"` fallback goes away.

### 3. Lookup before insert instead of `unique_constraint/3`

Rule (`ecto-phoenix.md`): *Validate input with changesets*, "Declare database constraints in the changeset (`unique_constraint/3` ...) so a violation returns `{:error, changeset}` instead of raising." `SKILL.md` names this exact shape, "a lookup before an insert", as a finding.

```elixir
if Repo.get_by(User, email: email) == nil do
  case Repo.insert(user) do
```

Two concurrent imports of the same address both pass the lookup; the second insert then raises on the index and is swallowed by `rescue _` as `:invalid`. Fix: `unique_constraint(:email)` in the changeset and drop the query.

### 4. `%User{...}` built from params and passed to `Repo.insert/1`

Rule (`ecto-phoenix.md`): *Validate input with changesets.* "A `%User{}` built from the params and passed to `Repo.insert/1` is the pattern to replace: Ecto inserts the struct as given, so nothing is validated."

```elixir
user = %User{email: email, age: age, role: role, nickname: nickname}
```

Fix: `cast/3`, `validate_required/2`, `validate_number/3` and `unique_constraint/3` on `%User{}`, in a private `import_changeset/1`. `cast/3` also replaces `String.to_integer/1` on the age (finding 6) and the atom conversion of the role (finding 5).

### 5. `String.to_atom(params["role"])` on external input

Rule: *Convert external strings to atoms with explicit clauses.* Atoms are never garbage-collected; whoever controls the CSV can exhaust the atom table and crash the node. The call also sits outside the `try`, so a missing `"role"` key raises `ArgumentError` straight to the caller. Fix: `cast/3` onto an `Ecto.Enum` field, which accepts only the listed values and adds a changeset error otherwise. If the schema stores a string, list the roles in explicit `parse_role/1` clauses instead.

### 6. `try ... rescue _ -> {:error, :invalid}` around the whole function

Rule: *Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs.* "Do not wrap a raising call in `try/rescue` to get a tuple ... never `rescue _ ->`."

```elixir
rescue
  _ -> {:error, :invalid}
```

A non-numeric age, a nil email, a bug in `Mailer`, and a database error all become `:invalid`, so the caller cannot tell a bad row from a broken system. Fix: the changeset reports each field's error and `Repo.insert/1` returns `{:error, changeset}`; nothing in the function raises on bad input anymore, so the `try` goes.

### 7. `_ -> {:error, :insert_failed}` after `{:ok, user}`

Rule: *Match every expected shape and let unexpected ones crash.* `Repo.insert/1` returns `{:error, changeset}`; the wildcard throws away the changeset that says what failed. Fix: let `with` pass `{:error, changeset}` through unchanged.

### 8. `notify: true, silent: false` are overlapping booleans

Rule: *Use one atom-valued field or option instead of overlapping booleans.* The skill's example is this call: `import_user(params, notify: true, silent: false)`.

```elixir
if opts[:notify] && !opts[:silent] do
```

`silent` only overrides `notify`, so `notify: true, silent: true` is a contradiction the caller can express. Fix: keep `:notify` only, check it with `Keyword.validate!(opts, notify: false)` (rule: *Group related parameters*), and document it under `## Options`.

### 9. `:return_id` changes the return shape

Rule: *Give each function one return shape.* "Options must not change what a function returns."

```elixir
if opts[:return_id], do: user.id, else: {:ok, user}
```

One mode returns a bare integer, the other a tuple, so no caller can match the result without knowing the option. Fix: always return `{:ok, user}`; a caller that wants the id reads `user.id`.

### 10. `is_binary(email) && age >= 18`

Rule: *Use `and`, `or`, `not` when the operands are booleans.* Both operands are booleans, so `and` documents and checks that. The check is also dead: `String.downcase/1` has already raised if `email` was not a binary. Fix: `validate_required([:email, ...])` and `validate_number(:age, greater_than_or_equal_to: @min_age)` in the changeset; the magic number 18 gets a name.

### 11. `params["email"] |> String.downcase()`

Rule: *Write pipelines that start with a value and read top to bottom.* "Do not pipe a single step." Fix: `String.downcase(params["email"])`, or in the changeset `update_change(:email, &String.downcase/1)`. The comment above it explains a reason the code cannot show and stays.

### 12. `if` inside `if` inside `case` inside `if` inside `try`

Rules: *Keep functions short and at one level of detail* ("When a `case`, `if`, or `with` appears inside another one, move the inner one into a named private function") and *Chain fallible steps with `with`*. Five levels of nesting in one public function. Fix: `import_user/2` becomes a `with` over `Repo.insert(import_changeset(params))`, with the validation in `import_changeset/1` and the nickname default in `default_nickname/1`. The one-step `with` is the pass-through form the rule allows: the body cannot fail and there is no `else`.

### 13. Bare `spawn/1` for the welcome email

Rule (`processes.md`): *Supervise every long-lived process.* "A bare `spawn/1` or `Task.start/1` outside a supervisor has none of this." Fire-and-forget work goes through `Task.Supervisor.start_child/2`.

```elixir
spawn(fn -> Mailer.deliver(welcome_email(user)) end)
```

The process is invisible to the supervision tree, so its crash (finding 2) is never reported. Fix: `Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(message) end)`.

### 14. The closure copies the whole `user` into the new process

Rule (`processes.md`): *Send processes only the data they need.* "All variables captured by an anonymous function passed to `spawn/1` ... are copied." Fix: build the message in the caller, `message = welcome_email(user)`, and capture only `message`.

### 15. `greeting |> (fn text -> ... end).()`

Rule: *Write pipelines that start with a value* ("Do not pipe into an anonymous function call") and *Name a step instead of wrapping an expression* (`name` and `greeting` each rename a value used once).

```elixir
greeting = "Hi " <> name <> ", welcome!"
greeting |> (fn text -> text <> " Enjoy your account." end).()
```

Fix: one interpolated string, `"Hi #{user.nickname}, welcome! Enjoy your account."`.

### 16. Comments that restate the code, no `@moduledoc` or `@doc`

Rule: *Comments explain why; documentation goes in `@moduledoc` and `@doc`.*

```elixir
# This module imports users from an external CSV/JSON source
# Import a single user from the given params
# Get the role from params
# send the email
```

Fix: delete the four, move the module description into `@moduledoc`, and document `import_user/2` and its `:notify` option in `@doc`. `library-design.md` asks for a `@spec` on every public function, so `import_user/2` gets one.

### 17. `alias Accounts.{Repo, User}` and no `import` grouping

Rule: *Open a module with `use`, `import`, `alias`, `require`, in that order.* The improved code imports `Ecto.Changeset` first, then lists one alias per line as the rule's example does.

## Improved code

Checked with `mix format --check-formatted` (Elixir 1.20.3). A compile check was not possible in this directory because the module depends on `Ecto.Changeset`, `Accounts.User`, `Accounts.Repo` and `Mailer`.

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  import Ecto.Changeset

  alias Accounts.Repo
  alias Accounts.User

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from string-keyed `params`.

  Returns `{:ok, user}` or `{:error, changeset}`, where the changeset names the
  field that was missing or invalid, or `:email` when the address is taken.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  @spec import_user(map(), keyword()) :: {:ok, %User{}} | {:error, Ecto.Changeset.t()}
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, user} <- Repo.insert(import_changeset(params)) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  defp import_changeset(params) do
    %User{}
    |> cast(params, [:email, :age, :role, :nickname])
    # The provider lowercases addresses before its uniqueness check, so match it here
    |> update_change(:email, &String.downcase/1)
    |> update_change(:age, &min(&1, @max_age))
    |> default_nickname()
    |> validate_required([:email, :age, :role])
    |> validate_number(:age, greater_than_or_equal_to: @min_age)
    |> unique_constraint(:email)
  end

  defp default_nickname(changeset) do
    case get_field(changeset, :nickname) do
      nil ->
        put_change(changeset, :nickname, get_field(changeset, :email))

      _nickname ->
        changeset
    end
  end

  defp send_welcome(user) do
    message = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(message) end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

Behaviour changes a caller will notice: the error is now `{:error, changeset}` instead of `{:error, :invalid}` or `:insert_failed`, the `:silent` and `:return_id` options are gone and `Keyword.validate!/2` raises if they are passed, and the age cap at 120 now applies.
