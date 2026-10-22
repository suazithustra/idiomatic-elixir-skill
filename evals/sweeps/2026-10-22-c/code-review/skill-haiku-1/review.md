# Review: `code-review-input.ex` (`Accounts.UserImporter`)

## Findings

Rules are from `idiomatic-elixir` (SKILL.md) and `references/processes.md`, `references/ecto-phoenix.md`.

1. **Bug: the age cap never applies.** Rule: *Assign the result of `if`, `case`, and `Enum` calls*.
   Line 15-17: `if age > 120 do age = 120 end`. The rebinding stays inside the `if`, so an age of 150 passes through unchanged and the compiler warns that the inner `age` is unused. Fix: `age = min(age, @max_age)`, or `update_change(:age, &min(&1, @max_age))` in the changeset.

2. **Bug: `user[:name]` raises on a struct.** Rule: *Read required keys with `map.key` or a pattern*; structs do not implement `Access`.
   Line 53: `name = user[:name] || "there"`. It raises `UndefinedFunctionError`, and the `User` struct, as far as this module shows, has no `name` field. The module sets `nickname`, which defaults to the email, so the fallback is dead code. Fix: `user.nickname` in the greeting.

3. **Bug: `String.to_atom/1` on external input.** Rule: *Convert external strings to atoms with explicit clauses*.
   Line 8: `role = String.to_atom(params["role"])`. It creates atoms from input (atom-table exhaustion) and raises on a missing key, outside the `try`. Fix: an `Ecto.Enum` field on `User`, so the changeset casts only the listed values. The role names in the improved version (`:admin`, `:member`) are placeholders; use the app's real roles.

4. **Catch-all `rescue` around the whole function.** Rule: *Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs*; `rescue` only specific exceptions.
   Line 42-43: `rescue _ -> {:error, :invalid}`. It hides bugs, including finding 2, and it can run after the insert has committed, so the caller sees `:invalid` for a user that exists. Fix: no `try` at all, because the only raising calls are removed (findings 5, 6).

5. **Raising parse instead of a non-raising one.** Rule: *Call the non-raising version instead*.
   Line 13: `age = String.to_integer(params["age"])`. A non-numeric age raises and is then swallowed by finding 4. Fix: let `cast/3` parse the age; it returns a changeset error for bad input.

6. **Single-step pipe and a raise on `nil`.** Rule: *Do not pipe a single step*.
   Line 12: `email = params["email"] |> String.downcase()`. A missing email raises `FunctionClauseError`. Fix: `update_change(:email, &String.downcase/1)` in the changeset, after `cast/3`, so a missing email becomes a `validate_required` error. The comment on line 11 explains a reason and stays, moved into the changeset.

7. **`&&` on booleans.** Rule: *Use `and`, `or`, `not` when the operands are booleans*.
   Line 21: `if is_binary(email) && age >= 18 do`. The `is_binary/1` check is also redundant: `email` came from `String.downcase/1`, which already requires a binary. Fix: the age rule becomes `validate_number(:age, greater_than_or_equal_to: @min_age)`.

8. **Lookup before insert instead of a constraint.** Rule (`ecto-phoenix.md`): *Declare database constraints in the changeset (`unique_constraint/3`)*.
   Line 24: `if Repo.get_by(User, email: email) == nil do`. Two concurrent imports both pass the check, and the second insert then fails or duplicates. Fix: `unique_constraint(:email)` in the changeset; the database index enforces uniqueness and the error comes back as `{:error, changeset}`. This assumes the `users.email` column has a unique index.

9. **Struct passed to `Repo.insert/1` with no changeset.** Rule (`ecto-phoenix.md`): *Cast and validate external input with `Ecto.Changeset`*.
   Line 22: `user = %User{email: email, age: age, role: role, nickname: nickname}`. Nothing is validated; the age check happens by hand in the `if` on line 21. Fix: `%User{} |> User.import_changeset(params) |> Repo.insert()`.

10. **Catch-all error clause on `Repo.insert`.** Rule: *Match every expected shape and let unexpected ones crash*.
    Line 33-34: `_ -> {:error, :insert_failed}`. Every failure becomes the same atom, and the changeset with the reason is dropped. Fix: `{:error, _changeset} = error -> error`.

11. **Overlapping booleans.** Rule: *Use one atom-valued field or option instead of overlapping booleans*.
    Line 27: `if opts[:notify] && !opts[:silent] do`. `notify: true, silent: true` is a meaningless combination. Fix: drop `:silent`; `notify: true` alone sends the email. This breaks callers that pass `silent:`; they must drop it.

12. **One function, two return shapes.** Rule: *Give each function one return shape*.
    Line 31: `if opts[:return_id], do: user.id, else: {:ok, user}`. Callers cannot know whether they get an integer or a tuple. Fix: `import_user/2` always returns `{:ok, user}`, and a new `import_user_id/2` returns `{:ok, id}`. This breaks callers that pass `return_id:`.

13. **Bare `spawn/1` for the welcome email.** Rule (`processes.md`): *Supervise every long-lived process*; *Send processes only the data they need*.
    Line 49: `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`. The process has no supervisor, and the closure captures the whole `user`. Fix: build the email in the caller, then `Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)`. `Accounts.TaskSupervisor` must be started in the application's supervision tree.

14. **Pipe into an anonymous function.** Rule: *Do not pipe into an anonymous function call*.
    Line 55: `greeting |> (fn text -> text <> " Enjoy your account." end).()`. Fix: build the text in one interpolated string.

15. **Nested conditionals and a `case` inside `if`.** Rule: *Branch with function clauses and guards before reaching for `if` or `cond`*; *Keep functions short and at one level of detail*.
    Lines 15-41: three levels of `if` and `case`, with `{:error, :invalid}` repeated three times. Fix: validation moves into the changeset, and `import_user/2` is one `case` over `insert_user/1`.

16. **Magic numbers.** Rule: *Name magic numbers with module attributes*.
    Lines 15, 21: `120` and `18`. Fix: `@max_age 120`, `@min_age 18`.

17. **Comments that restate the code, and the module comment placed as a comment.** Rule: *Comments explain why; documentation goes in `@moduledoc` and `@doc`*.
    Lines 2, 5, 7, 48: `# This module imports...`, `# Import a single user...`, `# Get the role from params`, `# send the email`. Fix: the module comment becomes `@moduledoc`, the function comment becomes `@doc` with `## Options` for `:notify`, and the restating comments are deleted. The comment on line 11 explains a reason and moves to the changeset.

## Improved version

`lib/accounts/user_importer.ex`:

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from external CSV and JSON sources.
  """

  alias Accounts.{Repo, User}

  @doc """
  Imports a single user from the given params.

  Returns `{:ok, user}` or `{:error, changeset}`. The changeset carries the
  validation and uniqueness errors.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    case insert_user(params) do
      {:ok, user} ->
        if opts[:notify], do: send_welcome(user)
        {:ok, user}

      {:error, _changeset} = error ->
        error
    end
  end

  @doc """
  Imports a single user and returns `{:ok, id}` or `{:error, changeset}`.

  Takes the same options as `import_user/2`.
  """
  def import_user_id(params, opts \\ []) do
    case import_user(params, opts) do
      {:ok, user} -> {:ok, user.id}
      {:error, _changeset} = error -> error
    end
  end

  defp insert_user(params) do
    %User{}
    |> User.import_changeset(params)
    |> Repo.insert()
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

Companion change to the `User` schema (`lib/accounts/user.ex`). The importer calls this function; the field list and role values are placeholders for the app's real ones:

```elixir
@min_age 18
@max_age 120

field :role, Ecto.Enum, values: [:admin, :member]

@doc """
Builds the changeset for an imported user.
"""
def import_changeset(user, params) do
  user
  |> cast(params, [:email, :age, :role, :nickname])
  |> update_change(:email, &String.downcase/1)
  |> update_change(:age, &min(&1, @max_age))
  |> validate_required([:email, :age, :role])
  |> validate_number(:age, greater_than_or_equal_to: @min_age)
  |> put_default_nickname()
  |> unique_constraint(:email)
end

defp put_default_nickname(changeset) do
  if get_field(changeset, :nickname) do
    changeset
  else
    put_change(changeset, :nickname, get_field(changeset, :email))
  end
end
```

The `String.downcase/1` step sits before `unique_constraint/3` so the uniqueness check runs against the lowercased address, which is what the original line 11 comment required.

## Caller changes to make

- Callers that pass `silent:` must drop it (finding 11).
- Callers that pass `return_id: true` must switch to `import_user_id/2` (finding 12).
- Callers that pattern-match `{:error, :invalid}` or `{:error, :insert_failed}` must match `{:error, %Ecto.Changeset{}}` (findings 4, 10).
- The app needs an `Accounts.TaskSupervisor` in its supervision tree (finding 13).
- The `users.email` column needs a unique index for `unique_constraint/3` to enforce uniqueness (finding 8).

## Not verified

The improved code was not compiled or run: there is no Mix project or `User` schema here, and `Mailer` is not defined in the input. The `User.import_changeset/2` snippet and the role values are assumptions about the surrounding app.
