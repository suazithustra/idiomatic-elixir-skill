# Review: Accounts.UserImporter

## Findings

1. **Age cap does nothing (bug).** `if age > 120 do age = 120 end` assigns inside the `if`. Elixir does not carry that assignment out, so `age` stays unchanged and the compiler warns that the variable is unused. Fix: `age = min(age, 120)`.

2. **`String.to_atom/1` on input (security).** Each distinct role string creates a permanent atom, and atoms are never garbage collected. An untrusted file can fill the atom table and crash the VM (virtual machine). It also sits outside the `try`, so a missing role (`nil`) crashes the caller. Fix: look the role up in a fixed map of allowed roles.

3. **`try/rescue` hides every error.** A typo, a database outage, or a bug in `send_welcome` all come back as `{:error, :invalid}`. The `rescue` is only there because `String.downcase(nil)` and `String.to_integer("abc")` raise. Fix: validate with pattern matching and `Integer.parse/1` inside a `with`, and let unexpected errors crash.

4. **Email check is in the wrong place.** `String.downcase` runs before `is_binary(email)`, so a non-string email raises before the check can reject it. Fix: check `is_binary` first.

5. **Check-then-insert race.** `Repo.get_by` followed by `Repo.insert` lets two concurrent imports of the same email both pass the check. Fix: add a unique index on `email` and a `unique_constraint` in a changeset, then handle the error from the insert.

6. **No changeset.** `Repo.insert(%User{...})` skips validation and gives no error detail. Fix: use `User.import_changeset/2` (assumed to exist or be added) and return `{:error, changeset}`.

7. **Errors are collapsed.** Duplicate email, under-age, and bad input all return `:invalid`, and insert failures drop the reason. Callers cannot tell what to fix. Fix: return distinct reasons (`:invalid_email`, `:invalid_age`, `:under_age`, `:invalid_role`, `:email_taken`).

8. **Return type depends on an option.** `return_id: true` returns a bare id, otherwise `{:ok, user}`. Fix: always return `{:ok, user}`. This changes behavior for any caller using `return_id`.

9. **`welcome_email/1` crashes.** `user[:name]` uses the Access behaviour, which structs do not implement, so it raises. In the original this happens inside the unsupervised process, so it fails silently. The user has `email` and `nickname` but no `name` is set by this module, so the improved version uses `nickname`. The string building through an anonymous function is also needlessly indirect.

10. **Unsupervised `spawn`.** A failed or slow mail delivery is lost with no log or retry. `Mailer` is also not aliased. Fix: `Task.Supervisor.start_child/2` under a supervisor in the application tree (`Accounts.TaskSupervisor`, assumed name), and alias `Mailer`.

11. **Style.** `&&` and `!` should be `and` and `not` for booleans. `opts[:notify] && !opts[:silent]` is redundant; the improved version keeps only `notify`. Comments that restate the code ("Get the role from params", "send the email") are removed. The comment on lowercasing is kept because it explains why. `@moduledoc` and `@spec` added. The `import_user/2` nesting of `if`/`case`/`if` is flattened with `with`.

12. **Age as an integer.** JSON input may already be an integer, and `String.to_integer/1` raises on that. The improved version accepts both.

## Assumptions to check

- The allowed roles are `admin` and `member`. Replace with the real list.
- `User.import_changeset/2` and a unique index on `email` exist or will be added.
- `Accounts.TaskSupervisor` is started in the application supervision tree.
- Capping age at 120 is intended; if it should reject instead, return `{:error, :invalid_age}`.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from external CSV/JSON params.
  """

  alias Accounts.{Mailer, Repo, User}

  @roles %{"admin" => :admin, "member" => :member}
  @min_age 18
  @max_age 120

  @type error ::
          :invalid_email
          | :invalid_age
          | :under_age
          | :invalid_role

  @doc """
  Imports one user. Options: `notify: true` sends a welcome email.
  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, error() | Ecto.Changeset.t()}
  def import_user(params, opts \\ []) do
    with {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         {:ok, role} <- parse_role(params["role"]),
         {:ok, user} <- insert(email, age, role, params["nickname"]) do
      if Keyword.get(opts, :notify, false), do: send_welcome(user)
      {:ok, user}
    end
  end

  # The provider lowercases addresses before its uniqueness check, so match it here.
  defp parse_email(email) when is_binary(email), do: {:ok, String.downcase(email)}
  defp parse_email(_), do: {:error, :invalid_email}

  defp parse_age(age) when is_integer(age), do: check_age(age)

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {int, ""} -> check_age(int)
      _ -> {:error, :invalid_age}
    end
  end

  defp parse_age(_), do: {:error, :invalid_age}

  defp check_age(age) when age >= @min_age, do: {:ok, min(age, @max_age)}
  defp check_age(_), do: {:error, :under_age}

  defp parse_role(role) do
    case Map.fetch(@roles, role) do
      {:ok, _} = ok -> ok
      :error -> {:error, :invalid_role}
    end
  end

  defp insert(email, age, role, nickname) do
    attrs = %{email: email, age: age, role: role, nickname: nickname || email}

    %User{}
    |> User.import_changeset(attrs)
    |> Repo.insert()
  end

  defp send_welcome(user) do
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn ->
      user |> welcome_email() |> Mailer.deliver()
    end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname || "there"}, welcome! Enjoy your account."
  end
end
```
