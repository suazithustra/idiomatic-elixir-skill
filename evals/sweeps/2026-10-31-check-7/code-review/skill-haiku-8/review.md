# Review: Accounts.UserImporter

## Findings

1. **Age cap never applies.** Rule: "Assign the result of `if`, `case`, and `Enum` calls". Line 15-17: `if age > 120 do age = 120 end` rebinds `age` inside the `if`, so the outer `age` stays as entered and users over 120 are stored unchanged. Fix: `Changeset.update_change(:age, &min(&1, @max_age))`.

2. **Welcome email crashes.** Rule: "Structs do not implement `Access`". Line 53: `user[:name] || "there"` raises `UndefinedFunctionError` whenever `notify: true`, and the `User` struct built on line 22 has no `name` field; the import sets `nickname`. Fix: read `user.nickname`.

3. **External input becomes an atom.** Rule: "Convert external strings to atoms with explicit clauses". Line 8: `role = String.to_atom(params["role"])` lets any caller add atoms to the VM's atom table (a fixed-size lookup table; it is never freed), and it raises for a missing role before the `try` runs. Fix: cast `role` through the changeset, with the schema declaring `role` as an `Ecto.Enum` so only known values convert.

4. **Catch-all rescue hides bugs.** Rule: "rescue the specific exception, never `rescue _ ->` ... around a whole function". Line 42-43: `rescue _ -> {:error, :invalid}` turns database failures and programming errors into "invalid input". Fix: remove the `try`; use functions that return tuples.

5. **Bad age raises.** Rule: "Return `{:ok, value}` or `{:error, reason}` for expected failures". Line 13: `String.to_integer(params["age"])` raises on `"abc"` or a missing key, and the `rescue` above it then hides the cause. Fix: `cast/4` reports a bad integer as a changeset error.

6. **Validation is done by hand, and one check is dead.** Rule: "Validate input with changesets" (`references/ecto-phoenix.md`). Line 21: `if is_binary(email) && age >= 18 do` checks fields by hand. The `is_binary` test can never fail, because line 12 already calls `String.downcase/1`, which raises on a non-string. Fix: `validate_required/2` and `validate_number/3` in the changeset. The nested `if` chain on lines 15-41 then disappears.

7. **Uniqueness is checked before the insert.** Rule: "Declare database constraints in the changeset (`unique_constraint/3`)". Line 24: `if Repo.get_by(User, email: email) == nil do` misses duplicates from two requests that run at the same time. Fix: `unique_constraint(:email)` in the changeset, with a unique index on `users.email`; the database then rejects the second insert.

8. **Struct inserted without validation.** Rule: "Validate input with changesets". Line 22 and 25: `%User{email: email, ...}` goes straight to `Repo.insert(user)`, so nothing is checked. Fix: build the changeset from `%User{}` and `params`, and insert that.

9. **Insert failures are swallowed.** Rule: "Match every expected shape and let unexpected ones crash". Line 33-34: `_ -> {:error, :insert_failed}` hides the reason and any new return shape. Fix: `with {:ok, user} <- Repo.insert(...)` passes `{:error, changeset}` back unchanged.

10. **One error reason covers unrelated failures.** Rule: "Different failures need different reasons". Lines 37 and 40-41 return `{:error, :invalid}` for a duplicate email, a too-young user, and a bad input alike. Fix: the changeset names each field and the reason, so a caller can tell them apart.

11. **Overlapping options.** Rule: "Use one atom-valued field or option instead of overlapping booleans". Line 27: `opts[:notify] && !opts[:silent]` lets `notify: true, silent: true` mean "no email". Fix: drop `:silent`; a caller who does not want the email omits `notify`. Callers that pass both flags will now get an email.

12. **One function, two return shapes.** Rule: "Give each function one return shape". Line 31: `if opts[:return_id], do: user.id, else: {:ok, user}` returns an integer in one mode and a tuple in the other. Fix: drop `:return_id`; callers read `user.id` from `{:ok, user}`.

13. **Unsupervised process.** Rule: "Supervise every long-lived process". Line 49: `spawn(fn -> Mailer.deliver(welcome_email(user)) end)` is not under a supervisor, so a crash is lost and the process does not show in tools such as Observer. The closure also captures the whole `user` struct. Fix: build the email first, then `Task.Supervisor.start_child/2` with a closure that captures only the email.

14. **Comments restate code; no module or function docs.** Rule: "Comments explain why; documentation goes in `@moduledoc` and `@doc`". Line 2, 7, and 48 repeat what the code says, and line 5 is a plain comment where `@doc` belongs. The module has no `@moduledoc`. Fix: add `@moduledoc` and a `@doc` with `## Options`; delete the restating comments. Keep the line 11 comment, which gives the reason for the lowercasing.

15. **Pipe into an anonymous function, and string building by hand.** Rule: "Do not pipe into an anonymous function call". Line 54-55 build the greeting with `<>`, then pipe it into `(fn text -> ... end).()`. Fix: one interpolated string, `"Hi #{user.nickname}, welcome! Enjoy your account."`.

16. **Single-step pipe.** Rule: "Do not pipe a single step". Line 12: `params["email"] |> String.downcase()`. Fix: the changeset lowercases the email with `update_change/3`, and the comment on line 11 stays above it.

## Improved module

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports single users from external CSV (comma-separated values) or JSON rows.
  """

  alias Accounts.{Repo, User}
  alias Ecto.Changeset

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from string-keyed params.

  Returns `{:ok, user}`, or `{:error, changeset}` where the changeset names
  each invalid field.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    with {:ok, user} <- Repo.insert(changeset(params)) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  defp send_welcome(user) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end

  defp changeset(params) do
    # The provider lowercases addresses before its uniqueness check, so match it here
    %User{}
    |> Changeset.cast(params, [:email, :age, :role, :nickname])
    |> Changeset.update_change(:email, &String.downcase/1)
    |> Changeset.update_change(:age, &min(&1, @max_age))
    |> default_nickname()
    |> Changeset.validate_required([:email, :age, :role])
    |> Changeset.validate_number(:age, greater_than_or_equal_to: @min_age)
    |> Changeset.unique_constraint(:email)
  end

  defp default_nickname(changeset) do
    email = Changeset.get_field(changeset, :email)
    nickname = Changeset.get_field(changeset, :nickname) || email
    Changeset.put_change(changeset, :nickname, nickname)
  end
end
```

## Assumptions and changes for callers

- `User` declares `role` as `Ecto.Enum` with the valid roles. If it does not, the role values must be listed in the changeset.
- A unique index on `users.email` exists. `unique_constraint(:email)` expects the default constraint name `users_email_index`.
- `Accounts.TaskSupervisor` is started in the application's supervision tree. It must be added if it is not.
- Errors are now `{:error, changeset}` instead of `{:error, :invalid}` or `{:error, :insert_failed}`. Callers that match those atoms must read the changeset's errors instead.
- The `:silent` and `:return_id` options are removed. Callers that passed them must change.
