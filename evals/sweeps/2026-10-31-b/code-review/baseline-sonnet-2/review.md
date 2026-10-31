# Review: Accounts.UserImporter

## Findings

1. **The age cap does nothing (bug).** `if age > 120 do age = 120 end` rebinds `age` only inside the `if`. Outside it, `age` is unchanged, so a 150-year-old is inserted as 150. The compiler warns about the unused variable. Fix: `min(age, 120)`.

2. **`String.to_atom/1` on input (security).** Each distinct role string creates a new atom, and atoms are never garbage collected, so a large import can exhaust the atom table (the VM crashes at about 1M atoms). It also sits outside the `try`, so a missing `"role"` raises `FunctionClauseError` instead of returning `{:error, _}`. Fix: match against an allow-list of role strings.

3. **`try/rescue` around everything.** It turns every failure (bad input, a database outage, a typo in the code) into `{:error, :invalid}`, so real bugs are invisible. Fix: parse input explicitly (`Integer.parse/1`, pattern matching) and return specific errors. Only expected failures should be handled.

4. **Check-then-insert race.** `Repo.get_by` followed by `Repo.insert` lets two concurrent imports of the same email both pass the check. Fix: rely on a unique index and `Ecto.Changeset.unique_constraint/2`, which turns the violation into an error tuple. This also removes one query per import.

5. **Misleading error reasons.** Underage, duplicate email and bad input all return `:invalid`, and an insert failure drops the changeset. Callers cannot tell them apart. Fix: return `:underage`, `:email_taken`, `:invalid_age`, `:invalid_role` and `{:error, changeset}`.

6. **Return type depends on options.** `return_id: true` returns a bare id, otherwise `{:ok, user}`. Callers must know the option to pattern match. Fix: always return `{:ok, user}`; the caller can read `user.id`. This changes the public behavior, so check callers first.

7. **Unsupervised `spawn` for email.** A crash in the mailer is lost silently and the work is not tracked on shutdown. Fix: `Task.Supervisor.start_child/2`. This assumes an `Accounts.TaskSupervisor` in the supervision tree.

8. **`welcome_email` crashes.** `user[:name]` uses the Access behaviour, which structs do not implement, so it raises. Because it runs inside `spawn`, the failure is silent and no welcome email is ever sent. The `User` struct built here also has no `name` field, only `nickname`. Fix: `user.nickname`.

9. **Dead and odd code.** `is_binary(email)` is always true after `String.downcase/1` (which would already have raised on non-binaries). `opts[:notify] && !opts[:silent]` is clumsier than `Keyword.get`. The `greeting |> (fn ... end).()` pipe is a roundabout way to write a string concatenation. `Mailer` is not aliased.

10. **Comments and docs.** Most comments restate the code ("Get the role from params"). The module has no `@moduledoc`, `@doc` or `@spec`. Keep only the comment explaining why emails are lowercased.

## Improved code

Assumptions: `@roles` lists the valid roles (adjust to the real set), `Accounts.Mailer` and `Accounts.TaskSupervisor` exist, and the `users.email` column has a unique index.

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from external CSV/JSON params.
  """

  import Ecto.Changeset, only: [change: 2, unique_constraint: 2]

  alias Accounts.{Mailer, Repo, TaskSupervisor, User}

  @roles %{"admin" => :admin, "member" => :member}
  @min_age 18
  @max_age 120

  @type error ::
          :invalid_email
          | :invalid_age
          | :invalid_role
          | :underage
          | {:insert_failed, Ecto.Changeset.t()}

  @doc """
  Imports a single user.

  Options:

    * `:notify` - send a welcome email after insert (default `false`)
  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, error()}
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

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {n, ""} when n >= @min_age -> {:ok, min(n, @max_age)}
      {_, ""} -> {:error, :underage}
      _ -> {:error, :invalid_age}
    end
  end

  defp parse_age(_), do: {:error, :invalid_age}

  defp parse_role(role) do
    case Map.fetch(@roles, role) do
      {:ok, _} = ok -> ok
      :error -> {:error, :invalid_role}
    end
  end

  defp insert(email, age, role, nickname) do
    %User{}
    |> change(email: email, age: age, role: role, nickname: nickname || email)
    |> unique_constraint(:email)
    |> Repo.insert()
    |> case do
      {:ok, user} -> {:ok, user}
      {:error, changeset} -> {:error, {:insert_failed, changeset}}
    end
  end

  defp send_welcome(user) do
    Task.Supervisor.start_child(TaskSupervisor, fn ->
      Mailer.deliver(welcome_email(user))
    end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```
