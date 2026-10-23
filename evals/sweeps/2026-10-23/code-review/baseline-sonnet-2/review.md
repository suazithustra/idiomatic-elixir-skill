# Review: Accounts.UserImporter

## Findings

1. **Untrusted input is turned into atoms.** `String.to_atom(params["role"])` creates a new atom for every distinct role string. Atoms are never garbage collected, so a large import can exhaust the VM's atom table and crash the node. It also raises on a missing role, and it sits outside the `try`, so that error escapes. Fix: map role strings to atoms through a fixed list.

2. **`try/rescue` hides bugs.** It catches every exception and returns `{:error, :invalid}`. A database outage, a typo or a missing `Mailer` all look like bad input. Fix: validate explicitly and return specific errors, and let real failures crash.

3. **The age cap does nothing.** `if age > 120 do age = 120 end` rebinds `age` only inside the `if`. The outer `age` is unchanged, and the compiler warns about it. Fix: `min(age, 120)`.

4. **The `is_binary(email)` check is useless.** `String.downcase/1` has already raised on a non-string by then. Validate before transforming.

5. **Check-then-insert race.** `Repo.get_by` followed by `Repo.insert` lets two concurrent imports of the same email both pass the check. Fix: insert through a changeset with `unique_constraint(:email)`, backed by a unique database index. The index must exist. Add one if it doesn't.

6. **Wrong error for duplicates.** A duplicate email returns `{:error, :invalid}`, the same as a bad age. Callers can't tell them apart. Insert failures also drop the changeset errors. Fix: return `{:error, :already_exists}`, `{:error, :underage}` and `{:error, changeset}`.

7. **The return type depends on an option.** `return_id: true` returns a bare id, otherwise `{:ok, user}`. Callers have to know the option to pattern match. Fix: always return `{:ok, user}`; the caller can read `user.id`.

8. **Unsupervised `spawn`.** If the mailer fails, nothing logs or restarts it, and the work is lost on shutdown. Fix: `Task.Supervisor.start_child/2` under a supervisor in the application tree (assumed name `Accounts.TaskSupervisor`).

9. **`welcome_email/1` is broken.** `user[:name]` uses the Access behaviour, which structs don't implement, so it raises. The raise happens inside the spawned process, so it is silent. Also, `User` has `nickname`, not `name`. The function wraps a concatenation in an anonymous function for no reason. Fix: read `user.nickname` and use one string.

10. **Smaller points.** `opts[:notify] && !opts[:silent]` is clearer as `Keyword.get(opts, :notify, false) and not Keyword.get(opts, :silent, false)`. Most comments restate the code and can go. The comment about the provider lowercasing addresses explains a reason, so it stays. `Mailer` is not aliased and may not resolve. I assumed `Accounts.Mailer`.

## Assumptions

The code needs three things I could not see: the real role list (I used `admin`, `member`), the `User` schema fields, and the name of the task supervisor. Check these before use.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc "Imports users from an external CSV/JSON source."

  import Ecto.Changeset

  alias Accounts.{Mailer, Repo, User}

  @roles %{"admin" => :admin, "member" => :member}
  @min_age 18
  @max_age 120

  @spec import_user(map(), keyword()) ::
          {:ok, User.t()} | {:error, atom() | Ecto.Changeset.t()}
  def import_user(params, opts \\ []) do
    with {:ok, role} <- parse_role(params["role"]),
         {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         {:ok, user} <- insert(email, age, role, params["nickname"]) do
      if Keyword.get(opts, :notify, false) and not Keyword.get(opts, :silent, false) do
        send_welcome(user)
      end

      {:ok, user}
    end
  end

  defp parse_role(role) when is_binary(role), do: Map.fetch(@roles, role) |> tag_error(:invalid_role)
  defp parse_role(_), do: {:error, :invalid_role}

  # The provider lowercases addresses before its uniqueness check, so match it here
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

  defp insert(email, age, role, nickname) do
    %User{}
    |> change(email: email, age: age, role: role, nickname: nickname || email)
    |> unique_constraint(:email)
    |> Repo.insert()
    |> case do
      {:error, %Ecto.Changeset{errors: [email: {_, [constraint: :unique | _]}]}} ->
        {:error, :already_exists}

      other ->
        other
    end
  end

  defp send_welcome(user) do
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn ->
      Mailer.deliver(welcome_email(user))
    end)
  end

  defp welcome_email(user) do
    name = user.nickname || "there"
    "Hi #{name}, welcome! Enjoy your account."
  end

  defp tag_error({:ok, _} = ok, _reason), do: ok
  defp tag_error(:error, reason), do: {:error, reason}
end
```
