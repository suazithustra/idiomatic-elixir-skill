# Review: `Accounts.UserImporter`

References read: `SKILL.md`, `references/processes.md` (for `spawn`), `references/ecto-phoenix.md` (for `Repo`).

## Findings

1. **Convert external strings to atoms with explicit clauses** (line 8)
   `role = String.to_atom(params["role"])`
   Anyone who controls the import source can exhaust the atom table. Also, a `nil` role raises `ArgumentError` before the `try`, so a missing role crashes the caller. Fix: `parse_role/1` clauses that list the accepted roles and return `{:error, {:invalid_field, "role"}}` for anything else.

2. **Return tuples for expected failures; never `rescue _ ->` around a whole function** (lines 10–44)
   `try do ... rescue _ -> {:error, :invalid} end`
   The `try` wraps `String.to_integer/1` and `String.downcase(nil)` to get a tuple, and it also swallows every bug in the body, including in the `Repo` call. Fix: use the non-raising `Integer.parse/1`, check fields with `string_field/2`, and drop the `try`.

3. **Assign the result of `if`; rebinding inside a block does not escape it** (lines 15–17)
   `if age > 120 do age = 120 end`
   The clamp does nothing, and the compiler warns that `age` is unused. Fix: `age: min(age, @max_age)`.

4. **Check required keys one field at a time; don't pipe a single step** (lines 12–13)
   `email = params["email"] |> String.downcase()` / `age = String.to_integer(params["age"])`
   Reading required keys with `params["key"]` turns a missing field into an unrelated crash, and the caller only ever sees `:invalid`. Fix: `string_field/2` returns `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}`, and the checks are chained in `with`. Downcase with `String.downcase(raw_email)`, without the pipe.

5. **Use `and`/`or`/`not` when the operands are booleans** (lines 21 and 27)
   `if is_binary(email) && age >= 18 do` and `if opts[:notify] && !opts[:silent] do`
   Also, `is_binary(email)` is always true once `String.downcase/1` has succeeded. Fix: the age check moves into the changeset (`validate_number/3`), and the options become a single boolean (finding 9).

6. **Validate input with changesets; declare `unique_constraint/3` instead of looking up before inserting** (lines 22–25)
   `user = %User{email: email, age: age, role: role, nickname: nickname}` / `if Repo.get_by(User, email: email) == nil do` / `Repo.insert(user)`
   Inserting a bare struct validates nothing. The `get_by` followed by `insert` is also a race: two concurrent imports can both see `nil`, and the second insert then raises on the unique index. Fix: build the record with `cast/3`, `validate_required/2`, `validate_number(:age, greater_than_or_equal_to: @min_age)` and `unique_constraint(:email)`, then call `Repo.insert/1`, so a duplicate returns `{:error, changeset}`. This needs a unique index on `users.email`. The changeset belongs in `User` (for example `User.import_changeset/2`, with `role` as an `Ecto.Enum`). It is written inline here only because `User` was not part of the input.

7. **Match every expected shape; no `_ ->` after `{:ok, value}`** (line 33)
   `_ -> {:error, :insert_failed}`
   This throws away the changeset that says why the insert failed. Fix: `with` passes `{:error, changeset}` through unchanged.

8. **Chain fallible steps with `with`; keep functions short and at one level of detail** (lines 21–41)
   Four levels of nested `if`/`case`, with `{:error, :invalid}` repeated. Fix: `import_user/2` is a two-step `with` (`parse_params/1`, then `insert_user/1`), and each step is a small private function that returns `{:ok, _}` or `{:error, reason}`.

9. **Use one option instead of overlapping booleans; validate options** (line 27)
   `opts[:notify] && !opts[:silent]`
   `notify: true, silent: true` is a combination that makes no sense. Fix: keep only `:notify`, check it with `Keyword.validate!(opts, notify: false)`, and document it under `## Options`.

10. **Give each function one return shape** (line 31)
    `if opts[:return_id], do: user.id, else: {:ok, user}`
    An option switches the return value from a tuple to a bare integer. Fix: always return `{:ok, user}`. Callers that want the id read `user.id`.

11. **Use atoms or tagged tuples as error reasons that callers can match on** (lines 37, 40, 43)
    `{:error, :invalid}` is returned for a duplicate email, an underage user, a malformed age and any crash alike. Fix: return `{:error, {:missing_field, key}}`, `{:error, {:invalid_field, key}}` or `{:error, changeset}`.

12. **Supervise every long-lived process; send processes only the data they need** (line 49)
    `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`
    The `spawn` is unsupervised, and the closure copies the whole `user` struct into the new process. Fix: build the email first, then run `Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)`. This requires `{Task.Supervisor, name: Accounts.TaskSupervisor}` in the application's supervision tree.

13. **Structs do not implement `Access`** (line 53)
    `name = user[:name] || "there"`
    `user` is a `%User{}`, so this raises `UndefinedFunctionError` and every welcome email crashes the spawned process. Fix: `user.name || "there"`. `||` is correct here because it supplies a default for a possibly-nil value. Note that the importer never sets `name`; if the greeting was meant to use the imported nickname, use `user.nickname` instead.

14. **Do not pipe into an anonymous function call** (line 55)
    `greeting |> (fn text -> text <> " Enjoy your account." end).()`
    Fix: one interpolated string.

15. **Comments explain why; document with `@moduledoc` / `@doc`** (lines 2, 5, 7, 48)
    `# This module imports users ...`, `# Import a single user ...`, `# Get the role from params`, `# send the email`
    Fix: add `@moduledoc`, and an `@doc` with `## Options` for `import_user/2`. Delete the comments that restate the code. The line-11 comment about the provider lowercasing addresses explains a reason, so it stays.

16. **Name magic numbers with module attributes** (lines 15, 21)
    `120` and `18`. Fix: `@max_age 120` and `@min_age 18`.

### Notes and assumptions

- **Roles:** the accepted roles (`"member"`, `"admin"`) are an assumption. The original accepted any string, so the real list has to come from the `User` schema. Because the role comes straight from external input, also consider whether an import should be able to create admins at all, or whether code should set the role (outside `cast/3`).
- **Behaviour changes:**
  - A duplicate email now returns `{:error, changeset}` instead of `{:error, :invalid}`.
  - `:return_id` and `:silent` are removed. `Keyword.validate!/2` raises if a caller still passes them.
- **`Mailer` namespace:** `Mailer` is still referenced unqualified, as in the original. If it is the app's own module, it should live under the app's namespace.
- **Verification:** the improved code passes `mix format --check-formatted`. It was not compiled, because `Accounts.User`, `Accounts.Repo`, `Mailer` and Ecto are not available here.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  import Ecto.Changeset

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from string-keyed `params`.

  Returns `{:ok, user}` on success, `{:error, {:missing_field, key}}` or
  `{:error, {:invalid_field, key}}` when a field is absent or unusable, and
  `{:error, changeset}` when validation or the unique email constraint fails.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, attrs} <- parse_params(params),
         {:ok, user} <- insert_user(attrs) do
      if Keyword.fetch!(opts, :notify), do: send_welcome(user)
      {:ok, user}
    end
  end

  defp parse_params(params) do
    with {:ok, raw_email} <- string_field(params, "email"),
         {:ok, age_text} <- string_field(params, "age"),
         {:ok, age} <- parse_age(age_text),
         {:ok, role_text} <- string_field(params, "role"),
         {:ok, role} <- parse_role(role_text) do
      # The provider lowercases addresses before its uniqueness check, so match it here
      email = String.downcase(raw_email)

      attrs = %{
        email: email,
        age: min(age, @max_age),
        role: role,
        nickname: params["nickname"] || email
      }

      {:ok, attrs}
    end
  end

  defp string_field(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp parse_age(text) do
    case Integer.parse(text) do
      {age, ""} -> {:ok, age}
      {_age, _rest} -> {:error, {:invalid_field, "age"}}
      :error -> {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_role("member"), do: {:ok, :member}
  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role(_role), do: {:error, {:invalid_field, "role"}}

  defp insert_user(attrs) do
    %User{}
    |> cast(attrs, [:email, :age, :role, :nickname])
    |> validate_required([:email, :age, :role, :nickname])
    |> validate_number(:age, greater_than_or_equal_to: @min_age)
    |> unique_constraint(:email)
    |> Repo.insert()
  end

  defp send_welcome(user) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user) do
    "Hi #{user.name || "there"}, welcome! Enjoy your account."
  end
end
```
