# Review: Accounts.UserImporter

## Findings

1. **Bug: the age cap does nothing.** `age = 120` inside the `if` only sets a variable local to that block. The outer `age` stays unchanged, so an age of 200 passes through as 200. The compiler warns about this. Fix: `min(age, 120)`.

2. **Security: `String.to_atom/1` on input.** Atoms (Elixir's interned symbols) are never garbage collected, and the VM crashes at about a million of them. Any imported file can create new ones. The call is also outside the `try`, so a missing `"role"` raises instead of returning an error. Fix: look the role up in a fixed map.

3. **`try/rescue` hides real failures.** It turns every exception into `{:error, :invalid}`, including database outages and typos in the code. Callers can't tell bad input from a broken system. Fix: validate with pattern matching and `with`, and let unexpected errors raise.

4. **Input handling is crash-driven.** A missing `"email"` or `"age"` raises in `String.downcase/1` or `String.to_integer/1`, and the rescue hides it. The later `is_binary(email)` check can never fail, because `downcase` already raised for non-strings. Fix: parse explicitly with `Integer.parse/1` and match on binaries.

5. **Race condition on duplicates.** `Repo.get_by` followed by `Repo.insert` lets two concurrent imports both pass the check. Fix: rely on a unique index and `unique_constraint(:email)` in a changeset (Ecto's validated change record), and map that error to `:email_taken`.

6. **No validation on insert.** Inserting a bare `%User{}` skips all changeset validation. Fix: go through `User.changeset/2`.

7. **Inconsistent return type.** `return_id: true` returns a bare id, and every other success returns `{:ok, user}`. Errors are `:invalid` for both bad input and duplicates, and the real insert error is dropped. Fix: always return `{:ok, user}` or `{:error, reason}`, with distinct reasons. Callers that use `:return_id` must switch to `user.id`.

8. **Unsupervised `spawn` for email.** A failure in `Mailer.deliver` is silent and the process is untracked. Fix: `Task.Supervisor.start_child/2`.

9. **`welcome_email/1` is broken.** `user[:name]` uses the Access protocol (the `[]` lookup), which structs don't implement, so it raises inside the spawned process and no email goes out. The pipe into an inline anonymous function is also needless. Fix: use `user.nickname` and plain string interpolation. I assumed `Mailer.deliver/1` takes whatever the old code built.

10. **Smaller items.** `opts[:notify] && !opts[:silent]` reads better as `Keyword.get(opts, :notify, false) and not Keyword.get(opts, :silent, false)`. Comments that restate the code ("Get the role from params", "send the email") should go. `Mailer` is not aliased.

## Assumptions

- `Accounts.User.changeset/2` exists and has `unique_constraint(:email)`. The table has a unique index on email.
- Valid roles are `admin` and `member`. Replace the map with the real list.
- An `Accounts.TaskSupervisor` is started in the application's supervision tree.

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

  @type error :: :invalid_email | :invalid_age | :invalid_role | :underage | :email_taken | Ecto.Changeset.t()

  @doc """
  Imports one user. Options: `:notify` (send a welcome email, default `false`).
  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, error()}
  def import_user(params, opts \\ []) do
    with {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         {:ok, role} <- parse_role(params["role"]),
         {:ok, user} <- insert(%{email: email, age: age, role: role, nickname: params["nickname"] || email}) do
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

  defp parse_role(role), do: Map.fetch(@roles, role) |> role_result()

  defp role_result({:ok, _} = ok), do: ok
  defp role_result(:error), do: {:error, :invalid_role}

  defp insert(attrs) do
    case %User{} |> User.changeset(attrs) |> Repo.insert() do
      {:ok, user} -> {:ok, user}
      {:error, %Ecto.Changeset{errors: [{:email, {_, [constraint: :unique, _]}} | _]}} -> {:error, :email_taken}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp send_welcome(user) do
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn ->
      Mailer.deliver(welcome_email(user))
    end)
  end

  defp welcome_email(user), do: "Hi #{user.nickname}, welcome! Enjoy your account."
end
```

Note: the `insert/1` unique-constraint match depends on Ecto's error metadata shape. If that is too brittle for the codebase, return the changeset and let the caller inspect it.
