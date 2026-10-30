# Review: `Accounts.UserImporter`

## Findings

1. **Ages over 120 are never capped.** The rule is "Assign the result of `if`": `if age > 120 do age = 120 end` (line 15) rebinds `age` inside the `if`, and the new value does not leave the block. The stored age stays unchanged. Fix: `update_change(:age, &min(&1, @max_age))` in the changeset.

2. **Input strings become atoms.** `String.to_atom(params["role"])` (line 8) creates a new atom for every distinct value. The atom table is fixed in size and is never garbage-collected, so crafted input can crash the Erlang VM. Rule: "Convert external strings to atoms with explicit clauses." Fix: declare `role` as an `Ecto.Enum` field, which rejects unknown values.

3. **One `rescue` covers the whole function.** The `try` on line 10 and `rescue _ -> {:error, :invalid}` (lines 42–43) hide every failure, including a database error in `Repo.insert`, and report it as bad input. Rule: rescue specific exceptions and never `rescue _` around a whole function. Fix: remove the `try`; expected failures become changeset errors.

4. **Bad input raises instead of returning a tuple.** `String.to_integer(params["age"])` (line 13) raises on `"abc"` and on `nil`. Rule: "Return `{:ok, value}` or `{:error, reason}` for expected failures." Fix: `cast/3` parses the age and reports an error on the changeset.

5. **Uniqueness is checked before the insert.** `Repo.get_by(User, email: email) == nil` (line 24) followed by `Repo.insert` lets two imports of the same address both pass the check. Rule: declare the constraint with `unique_constraint/3`. Fix: `unique_constraint(:email)` in the changeset, so the database enforces it and the insert returns `{:error, changeset}`. This needs a unique index on `email`.

6. **A struct is inserted without validation.** `%User{email: email, age: age, role: role, nickname: nickname}` (line 22) goes straight to `Repo.insert/1` (line 25), and Ecto (the Elixir database library) inserts it as given. Rule: "Validate input with changesets." Fix: `User.import_changeset/2`, shown below.

7. **A catch-all hides the insert error.** `_ -> {:error, :insert_failed}` (line 33) discards the reason. Rule: "Match every expected shape and let unexpected ones crash." Fix: `with {:ok, user} <- Repo.insert(changeset)`, which passes the error through unchanged.

8. **Boolean checks use `&&` and nesting goes four levels deep.** `is_binary(email) && age >= 18` (line 21) sits inside nested `if` and `case` blocks. `&&` accepts any value, and the checks belong in the changeset. Rule: "Use `and`, `or`, `not` when the operands are booleans," and keep functions short. Fix: the checks move into the changeset, and `import_user/2` shrinks to a few lines.

9. **Options overlap and unknown options pass silently.** `opts[:notify] && !opts[:silent]` (line 27) makes `silent` a veto that only matters when `notify` is set, and a misspelled option name is ignored. Rule: "Use one atom-valued field or option instead of overlapping booleans," and "check them with `Keyword.validate!/2`." Fix: drop `:silent`, and call `Keyword.validate!(opts, notify: false)`, which raises on unknown keys.

10. **One function returns two shapes.** `if opts[:return_id], do: user.id, else: {:ok, user}` (line 31) returns an integer in one mode and a tuple in the other. Rule: "Give each function one return shape." Fix: remove `:return_id`; callers read `user.id` from `{:ok, user}`.

11. **A bare `spawn` runs outside any supervisor and copies the whole struct.** `spawn(fn -> Mailer.deliver(welcome_email(user)) end)` (line 49) has no supervisor, and the closure copies `user`. Rule: "Supervise every long-lived process" and "Send processes only the data they need." Fix: build the email first and start it with `Task.Supervisor.start_child/2`. This needs `Accounts.TaskSupervisor` in the application's supervision tree.

12. **`Access` is used on a struct.** `user[:name]` (line 53) raises `UndefinedFunctionError`, because structs do not implement `Access`. The import also sets `nickname`, not `name`. Rule: read struct fields with `user.field`. Fix: `user.nickname`, which the changeset always fills.

13. **An anonymous function is called inside a pipe.** Lines 54–55 join strings with `<>` and then pipe the result into `(fn text -> ... end).()`. Rule: "Do not pipe into an anonymous function call." Fix: one interpolated string.

14. **A single-step pipe, and a `nil` email raises.** `params["email"] |> String.downcase()` (line 12) is one step written as a pipe. A missing email raises `FunctionClauseError`, which the `rescue` then hid. Rule: "Do not pipe a single step." Fix: `update_change(:email, &String.downcase/1)` in the changeset, after the required-field check.

15. **Comments restate code or sit in the wrong place.** Line 2 describes the module and should be `@moduledoc`. Line 5 describes a function and should be `@doc`. Lines 7 and 48 restate the next line, so they go. Line 11 gives a reason and stays, moved above the email change in the changeset. Rule: "Comments explain why; documentation goes in `@moduledoc` and `@doc`."

Behavior changes a caller will notice: errors are now `{:error, changeset}` instead of `{:error, :invalid}` or `{:error, :insert_failed}`; the `:return_id` and `:silent` options are gone; ages over 120 are stored as 120, which the original code meant to do but did not; database errors now raise instead of returning `{:error, :invalid}`.

Assumptions to check against the real project: the `User` schema has fields `email`, `age`, `role`, and `nickname`; `role` is an `Ecto.Enum` (its values are a guess, `[:admin, :editor, :member]`); a unique index exists on `email`; and `Accounts.TaskSupervisor` is started in the application. The `@doc` has no `## Examples` section, because the function needs a database and cannot run as a doctest.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV (comma-separated values) or JSON source.
  """

  alias Accounts.{Repo, User}

  @doc """
  Imports a single user from string-keyed params.

  Returns `{:ok, user}` or `{:error, changeset}`. The changeset carries the
  validation errors, such as an email that is already taken.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)
    changeset = User.import_changeset(%User{}, params)

    with {:ok, user} <- Repo.insert(changeset) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  defp send_welcome(user) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user), do: "Hi #{user.nickname}, welcome! Enjoy your account."
end
```

## Companion changeset

This function goes in the `Accounts.User` schema module. It needs `import Ecto.Changeset` at the top of that module.

```elixir
@max_age 120
@min_age 18

@doc """
Casts and validates a user imported from an external source.
"""
def import_changeset(user, params) do
  user
  |> cast(params, [:email, :age, :role, :nickname])
  |> validate_required([:email, :age, :role])
  # The provider lowercases addresses before its uniqueness check, so match it here
  |> update_change(:email, &String.downcase/1)
  |> validate_number(:age, greater_than_or_equal_to: @min_age)
  |> update_change(:age, &min(&1, @max_age))
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

`Ecto.Enum` for `role` is declared in the schema, for example `field :role, Ecto.Enum, values: [:admin, :editor, :member]`. The values listed there are the ones the import accepts.
