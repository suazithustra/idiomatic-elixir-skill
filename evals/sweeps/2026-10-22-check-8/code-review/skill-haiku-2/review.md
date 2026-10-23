# Review: `Accounts.UserImporter`

Rules cited are from `idiomatic-elixir/SKILL.md` unless marked `processes.md` or `ecto-phoenix.md`.

## Findings

1. **Atoms created from external input.** Rule: *Convert external strings to atoms with explicit clauses*.
   Line 8: `role = String.to_atom(params["role"])`. Any caller can grow the atom table, and a `nil` role raises outside the `try`.
   Fix: let the schema cast the role (`Ecto.Enum` in `User`), so no atom is created from input.

2. **Catch-all `rescue` around the whole function.** Rule: *Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs*: never `rescue _ ->` around a whole function.
   Lines 42-43: `rescue _ -> {:error, :invalid}` hides programming errors as "invalid input".
   Fix: remove the `try`; the changeset reports invalid input as data.

3. **Raising parse for expected input.** Rule: *Call the non-raising version*.
   Line 13: `age = String.to_integer(params["age"])` raises on `"abc"` or `nil`.
   Fix: `Integer.parse/1` in `clamp_age/1`, with the bad value left for the changeset to reject.

4. **Clamp never happens.** Rule: *Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it*.
   Lines 15-17: `if age > 120 do age = 120 end` leaves `age` unchanged, so the value is never clamped (the compiler also warns).
   Fix: `min(value, @max_age)`.

5. **Magic number.** Rule: *Name magic numbers with module attributes*.
   Line 15: `120`. Fix: `@max_age 120`.

6. **Boolean `&&` on values that are not booleans, and a check-then-insert.** Rules: *Use `and`, `or`, `not` when the operands are booleans*; *Validate input with changesets* (uniqueness via `unique_constraint/3`, `ecto-phoenix.md`).
   Line 21: `if is_binary(email) && age >= 18 do`, and line 24: `if Repo.get_by(User, email: email) == nil do`.
   The lookup before insert is a race (two imports can both pass the check), and the `is_binary` and age checks duplicate what a changeset validates.
   Fix: `User.changeset/2` with `validate_required`, `validate_number(:age, greater_than_or_equal_to: 18)`, and `unique_constraint(:email)`.

7. **Struct inserted without validation.** Rule: *Validate input with changesets* (`ecto-phoenix.md`).
   Line 22-25: `%User{email: email, age: age, role: role, nickname: nickname}` then `Repo.insert(user)`. Ecto inserts the struct as given and a constraint violation raises.
   Fix: `%User{} |> User.changeset(attrs) |> Repo.insert()`.

8. **Catch-all error clause hides the error.** Rule: *Match every expected shape and let unexpected ones crash*.
   Line 33: `_ -> {:error, :insert_failed}` turns the changeset error into a generic atom.
   Fix: `{:error, _changeset} = error -> error`.

9. **Overlapping booleans.** Rule: *Use one atom-valued field or option instead of overlapping booleans*.
   Line 27: `if opts[:notify] && !opts[:silent] do`. `notify: true, silent: true` is a meaningless combination.
   Fix: drop `:silent`, as in the rule's own example. Callers that pass `silent:` must be updated (see Notes).

10. **Options change the return shape.** Rule: *Give each function one return shape*.
    Line 31: `if opts[:return_id], do: user.id, else: {:ok, user}` returns a bare integer in one mode and a tuple in the other.
    Fix: `import_user/2` always returns `{:ok, user}`; a new `import_user_id/2` returns `{:ok, id}`.

11. **Options not validated or documented.** Rule: *Group related parameters*: check options with `Keyword.validate!/2` and document them under `## Options`.
    Line 6: `def import_user(params, opts \\ [])` takes `opts` with no check and no `@doc`.
    Fix: `Keyword.validate!(opts, notify: false)` and an `@doc` with `## Options`.

12. **Deep nesting: `try`, `if`, `case`, and `if` again.** Rules: *Branch with function clauses and guards before reaching for `if` or `cond`*; *Chain fallible steps with `with`*; *Keep functions short and at one level of detail*.
    Lines 10-44 nest four levels. Fix: private functions for normalization and insert; the public function is a short `case`.

13. **Bare `spawn`.** Rule: *Supervise every long-lived process* (`processes.md`).
    Line 49: `spawn(fn -> Mailer.deliver(welcome_email(user)) end)` runs outside any supervisor and is invisible to Observer.
    Fix: `Task.Supervisor.start_child/2`. The closure captures only the built email, not the user (`processes.md`, *Send processes only the data they need*).

14. **Access on a struct, and a field the struct does not have.** Rule: *Read required keys with `map.key` or a pattern*.
    Line 53: `name = user[:name] || "there"`. `User` does not implement `Access`, so this raises `UndefinedFunctionError`. The importer also never sets a `name`; it sets `nickname`.
    Fix: `user.nickname`.

15. **Pipe into an anonymous function, and a single-step pipe.** Rules: *Write pipelines that start with a value* (do not pipe into `(fn ...).()`, do not pipe a single step).
    Line 55: `greeting |> (fn text -> text <> " Enjoy your account." end).()`.
    Line 12: `params["email"] |> String.downcase()`.
    Fix: one interpolated string; `String.downcase/1` called directly.

16. **Comments restate the code, and the module lacks docs.** Rule: *Comments explain why; documentation goes in `@moduledoc` and `@doc`*.
    Line 2 (module description) belongs in `@moduledoc`. Line 5 (function description) belongs in `@doc`. Lines 7 (`# Get the role from params`) and 48 (`# send the email`) restate the code and are deleted.
    Line 11 explains a reason the code cannot show, so it stays, moved to the function that normalizes the email.

## Notes on the rewrite

- The rewrite assumes `User` has `changeset/2` that casts `email`, `age`, `role`, `nickname`; requires `email` and `age`; validates `age >= 18`; declares `role` as `Ecto.Enum`; and declares `unique_constraint(:email)`. If it does not, add those before using this module.
- The rewrite assumes an `Accounts.TaskSupervisor` is started in the application's supervision tree. Substitute the project's real name.
- Behaviour changes for callers: `:silent` and `:return_id` are no longer accepted (`Keyword.validate!/2` raises on unknown keys); `import_user/2` returns `{:error, changeset}` where it returned atoms; under-18 and invalid input now come back as changeset errors.
- The greeting now uses `nickname`, because the importer never sets `name`.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from external CSV and JSON sources.
  """

  alias Accounts.{Repo, User}

  @max_age 120

  @doc """
  Imports a single user from string-keyed params.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.

  Returns `{:ok, user}`, or `{:error, changeset}` when the params are invalid
  or the email is already taken.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    case insert_user(params) do
      {:ok, user} ->
        if opts[:notify], do: send_welcome(user)
        {:ok, user}

      {:error, _changeset} = error ->
        error
    end
  end

  @doc """
  Imports a single user like `import_user/2`, returning `{:ok, id}` on success.
  """
  def import_user_id(params, opts \\ []) do
    case import_user(params, opts) do
      {:ok, user} -> {:ok, user.id}
      {:error, _changeset} = error -> error
    end
  end

  defp insert_user(params) do
    %User{}
    |> User.changeset(normalize(params))
    |> Repo.insert()
  end

  defp normalize(params) do
    email = normalize_email(params["email"])

    %{
      email: email,
      age: clamp_age(params["age"]),
      role: params["role"],
      nickname: params["nickname"] || email
    }
  end

  # The provider lowercases addresses before its uniqueness check, so match it here.
  defp normalize_email(email) when is_binary(email), do: String.downcase(email)
  defp normalize_email(email), do: email

  defp clamp_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {value, ""} -> clamp_age(value)
      _ -> age
    end
  end

  defp clamp_age(age) when is_integer(age), do: min(age, @max_age)
  defp clamp_age(age), do: age

  defp send_welcome(user) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```
