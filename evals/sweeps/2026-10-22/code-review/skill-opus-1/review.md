# Review: `Accounts.UserImporter`

Line numbers refer to `code-review-input.ex`. Findings are ordered by severity.

## Findings

### 1. Any role string in the import becomes a permanent atom (line 8)

Rule: *Convert external strings to atoms with explicit clauses*. `role = String.to_atom(params["role"])` creates a new atom for every distinct role in the source data. Atoms are never freed, so a file with enough distinct values crashes the whole Erlang VM (virtual machine). The line is also outside the `try`, so a row with no role crashes the caller instead of returning an error. Fix: declare `field :role, Ecto.Enum, values: [...]` on `User` and cast `:role` in the changeset, which turns an unknown or missing role into a changeset error. The original inserts an atom into `:role`, so the field is probably `Ecto.Enum` already; if not, change it.

### 2. The user is inserted without a changeset (lines 12–13, 21–24)

Rule: *Validate input with changesets* (`references/ecto-phoenix.md`). `user = %User{email: email, age: age, role: role, nickname: nickname}` followed by `Repo.insert(user)` validates nothing, and a duplicate email raises instead of returning an error. The hand-written checks around it have their own problems. `params["email"]` and `params["age"]` read required keys as if they were optional. `is_binary(email) && age >= 18` uses `&&` on two booleans where `and` belongs, and `is_binary(email)` is always true at that point because `String.downcase/1` has already raised on a non-string. Fix: build an `import_changeset/2` with `cast/3`, `validate_required/2`, `validate_number/3` and `unique_constraint(:email)`, then call `Repo.insert/1` on the changeset.

### 3. `rescue _ ->` around the whole function hides every bug (lines 10, 38–39)

Rule: *Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs*. `rescue _ -> {:error, :invalid}` turns typos, database errors and the crash in finding 1 into the same `:invalid` result. It exists only because `String.to_integer(params["age"])` raises on bad input. Fix: remove the `try`. Casting `:age` as an `:integer` field returns a changeset error for input like `"3x"`.

### 4. The age cap never takes effect (lines 15–17)

Rule: *Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it*. `age = 120` inside `if age > 120 do` binds a new variable that disappears when the block ends, so ages over 120 are stored as given, and the compiler warns that the variable is unused. Fix: `update_change(:age, &min(&1, @max_age))` in the changeset. The numbers 120 and 18 become `@max_age` and `@min_age` (rule: *Name magic numbers with module attributes*).

### 5. Errors throw away the reason (lines 32–33, 36)

Rule: *Match every expected shape and let unexpected ones crash*. `_ -> {:error, :insert_failed}` and `{:error, :invalid}` tell the caller that something failed, but not which field or why. Fix: return `{:error, changeset}` unchanged, and match it explicitly as `{:error, _changeset} = error -> error`.

### 6. Welcome emails are never sent (line 49)

Rule: *Read required keys with `map.key` or a pattern* (structs do not implement `Access`). `name = user[:name] || "there"` raises `UndefinedFunctionError` on every call, because `user` is a `%User{}` struct. The crash happens inside the spawned process, so `import_user/2` still reports success and the only trace is an error in the log. Fix: `name = user.name || "there"`. The importer never sets `:name`, so the greeting will always read "Hi there"; if the source sends a name, add `:name` to the `cast/3` list.

### 7. The email is sent from an unsupervised process (line 45)

Rule: *Supervise every long-lived process* and *Send processes only the data they need* (`references/processes.md`). `spawn(fn -> Mailer.deliver(welcome_email(user)) end)` starts a process nothing supervises, and the closure copies the whole user struct into it. Fix: build the message first, then call `Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(message) end)`. This needs `{Task.Supervisor, name: Accounts.TaskSupervisor}` in the application's supervision tree.

### 8. Two booleans control one choice (line 26)

Rule: *Use one atom-valued field or option instead of overlapping booleans*. In `if opts[:notify] && !opts[:silent] do`, `:silent` only overrides `:notify`, so `notify: true, silent: true` makes no sense. Fix: keep `:notify` alone and check it with `Keyword.validate!(opts, notify: false)`. The private `notify/2` clauses match `true` and `false`, so a non-boolean value raises at the call site.

### 9. An option changes the return type (line 30)

Rule: *Give each function one return shape*. `if opts[:return_id], do: user.id, else: {:ok, user}` returns a bare integer in one mode and a tuple in the other, and the integer mode has no error case to match. Fix: always return `{:ok, user}`. Callers that want the ID match `{:ok, %User{id: id}}`.

### 10. Documentation is written as comments (lines 2, 5, 7, 44)

Rule: *Comments explain why; documentation goes in `@moduledoc` and `@doc`*. `# This module imports users from an external CSV/JSON source` and `# Import a single user from the given params` belong in `@moduledoc` and `@doc`. `# Get the role from params` and `# send the email` restate the code and should go. The comment on line 11 explains a reason the code cannot show, so it stays. Fix: add `@moduledoc`, and `@doc` with an `## Options` section. Add a `@spec` on `import_user/2` too (`references/library-design.md`).

### 11. Two pipelines that should not be pipelines (lines 12, 51)

Rule: *Write pipelines that start with a value and read top to bottom*. `params["email"] |> String.downcase()` pipes a single step, and `greeting |> (fn text -> text <> " Enjoy your account." end).()` pipes into an anonymous function. Fix: downcase inside the changeset with `update_change(:email, &String.downcase/1)`, and build the greeting as one interpolated string.

### 12. `Mailer` is a top-level module (line 45)

Rule: *Put every module under the top-level namespace of its own application*. `Mailer.deliver(...)` calls a module named plain `Mailer`, which can clash with any dependency that defines the same name. Fix: rename it `Accounts.Mailer` and alias it. The improved code assumes that rename.

## What changes for callers

- Failures return `{:error, %Ecto.Changeset{}}` instead of `{:error, :invalid}` or `{:error, :insert_failed}`.
- `:silent` and `:return_id` are gone; passing either raises `ArgumentError`.
- Ages over 120 are now stored as 120, which is what the original meant to do.
- Unknown roles are rejected, and a missing role returns an error instead of crashing.
- An empty nickname (`""`) now falls back to the email, because `cast/3` treats empty strings as missing.
- The code needs `Accounts.TaskSupervisor` in the supervision tree, `Ecto.Enum` on `User.role`, and `Accounts.Mailer`.

I checked the improved module in a scratch Mix project (`verify/`) with stub `Repo`, `User` and `Mailer` modules. `mix format --check-formatted` and `mix compile --warnings-as-errors` pass, and so do six ExUnit tests covering valid import, email downcasing, the nickname default, the age cap, rejected input, notify, and unknown options.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  import Ecto.Changeset

  alias Accounts.{Mailer, Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from string-keyed `params`.

  Returns `{:ok, user}`, or `{:error, changeset}` when the params are invalid
  or the insert fails.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  @spec import_user(map(), keyword()) :: {:ok, %User{}} | {:error, Ecto.Changeset.t()}
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    case insert_user(params) do
      {:ok, user} ->
        notify(user, opts[:notify])
        {:ok, user}

      {:error, _changeset} = error ->
        error
    end
  end

  defp insert_user(params) do
    %User{}
    |> import_changeset(params)
    |> Repo.insert()
  end

  defp import_changeset(user, params) do
    user
    |> cast(params, [:email, :age, :role, :nickname])
    |> validate_required([:email, :age, :role])
    # The provider lowercases addresses before its uniqueness check, so match it here
    |> update_change(:email, &String.downcase/1)
    |> put_default_nickname()
    |> update_change(:age, &min(&1, @max_age))
    |> validate_number(:age, greater_than_or_equal_to: @min_age)
    |> unique_constraint(:email)
  end

  defp put_default_nickname(changeset) do
    if get_field(changeset, :nickname) do
      changeset
    else
      put_change(changeset, :nickname, get_field(changeset, :email))
    end
  end

  defp notify(user, true), do: send_welcome(user)
  defp notify(_user, false), do: :ok

  defp send_welcome(user) do
    message = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(message) end)
  end

  defp welcome_email(user) do
    name = user.name || "there"
    "Hi #{name}, welcome! Enjoy your account."
  end
end
```
