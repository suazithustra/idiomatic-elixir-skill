# Review: Accounts.UserImporter

## Findings

1. **Age cap does nothing.** `if age > 120 do age = 120 end` rebinds `age` only inside the `if`. Elixir does not leak that binding out, so ages above 120 are stored unchanged (the compiler also warns about an unused variable). Fix: `min(age, 120)`.

2. **`String.to_atom/1` on external input.** Atoms are never garbage collected, so a stream of distinct role strings can exhaust the atom table and crash the VM (Erlang virtual machine). It also raises on a missing role, and that happens outside the `try`. Fix: look the role up in an explicit allowlist.

3. **`try/rescue` hides every failure.** A missing key, a bad integer, a database outage and a typo in this code all become `{:error, :invalid}`. Fix: use `with`, parse input with `Integer.parse/1`, and return a distinct error for each failure.

4. **Dead check.** `is_binary(email)` runs after `String.downcase/1`, which already raised if `email` was not a string. The check can never be false.

5. **Race condition on email uniqueness.** `Repo.get_by` followed by `Repo.insert` lets two concurrent imports both pass the check. Fix: insert through a changeset with `unique_constraint(:email)` and handle the error. This needs a unique index on `users.email`. I assume one exists.

6. **Inconsistent return type.** With `return_id: true` the function returns a bare id instead of `{:ok, user}`, so callers cannot pattern match on one shape. Fix: always return `{:ok, user}`.

7. **Error reasons are lost.** A duplicate email, an underage user and malformed input all return `:invalid`, and a failed insert drops the changeset errors. Fix: return specific atoms and `{:error, changeset}`.

8. **Redundant options.** `notify && !silent` means the same as `notify` alone for the combinations callers can usefully pass. Two flags that can contradict each other are confusing. Fix: keep only `:notify`.

9. **Unsupervised `spawn` for email.** If delivery fails, nothing logs or retries it, and the process is invisible to the supervision tree. Fix: use `Task.Supervisor.start_child/2`. This assumes a `Accounts.TaskSupervisor` in your supervision tree, which I have not seen.

10. **`welcome_email/1` is broken.** `user[:name]` uses the Access behaviour, which structs do not implement, so it raises. The importer never sets a `name` field anyway. It also concatenates with `<>`, which fails on `nil`, and pipes into an anonymous function for no reason. Fix: greet by `nickname` (always set) and build the string with interpolation. If `User` has a `name` field, use that instead.

11. **`Mailer` is not aliased or defined in this module.** It is called by a bare name, which only works if `Mailer` is a top-level module. Confirm that, or alias the correct module.

12. **Housekeeping.** Add `@moduledoc`, `@doc` and `@spec`. Remove comments that restate the code ("Get the role from params", "send the email"). Keep the comment explaining why email is downcased, since that reason is not visible in the code. Trim whitespace from the email as well.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV/JSON source.
  """

  import Ecto.Changeset, only: [change: 2, unique_constraint: 2]

  alias Accounts.{Repo, User}

  @roles %{"admin" => :admin, "member" => :member, "guest" => :guest}
  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from string-keyed `params`.

  Options:

    * `:notify` - send a welcome email after a successful insert (default `false`)

  Returns `{:ok, user}` or `{:error, reason}`.
  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, atom() | Ecto.Changeset.t()}
  def import_user(params, opts \\ []) do
    with {:ok, email} <- fetch_email(params),
         {:ok, age} <- fetch_age(params),
         {:ok, role} <- fetch_role(params),
         {:ok, user} <- insert(email, age, role, params["nickname"]) do
      if Keyword.get(opts, :notify, false), do: send_welcome(user)
      {:ok, user}
    end
  end

  # The provider lowercases addresses before its uniqueness check, so match it here.
  defp fetch_email(%{"email" => email}) when is_binary(email),
    do: {:ok, email |> String.trim() |> String.downcase()}

  defp fetch_email(_), do: {:error, :invalid_email}

  defp fetch_age(%{"age" => age}) when is_binary(age) do
    case Integer.parse(age) do
      {n, ""} when n >= @min_age -> {:ok, min(n, @max_age)}
      {_n, ""} -> {:error, :underage}
      _ -> {:error, :invalid_age}
    end
  end

  defp fetch_age(%{"age" => age}) when is_integer(age) and age >= @min_age,
    do: {:ok, min(age, @max_age)}

  defp fetch_age(%{"age" => age}) when is_integer(age), do: {:error, :underage}
  defp fetch_age(_), do: {:error, :invalid_age}

  defp fetch_role(%{"role" => role}) do
    case Map.fetch(@roles, role) do
      {:ok, _} = ok -> ok
      :error -> {:error, :invalid_role}
    end
  end

  defp fetch_role(_), do: {:error, :invalid_role}

  defp insert(email, age, role, nickname) do
    %User{}
    |> change(email: email, age: age, role: role, nickname: nickname || email)
    |> unique_constraint(:email)
    |> Repo.insert()
  end

  defp send_welcome(user) do
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn ->
      Mailer.deliver(welcome_email(user))
    end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

Notes on the rewrite:

- I could not compile this: I do not have the `User`, `Mailer` or `Accounts.TaskSupervisor` definitions.
