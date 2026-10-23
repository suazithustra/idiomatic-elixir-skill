# Review: `Accounts.UserImporter`

## Findings

1. **The age cap of 120 never applies.** The `if age > 120` block rebinds `age` inside the `if`, and Elixir does not carry that binding out. A row with age 150 is stored as 150. Fix: `min(age, 120)` in a plain expression.

2. **Welcome emails never send correctly.** `welcome_email/1` reads `user[:name]`. `User` is a struct, and Access (`[]`) does not work on structs unless the module implements it, so this raises. The raise happens inside `spawn/1`, so nothing is logged and the caller sees success. The import also never sets a `:name` field; the nickname is the field that is always set. Fix: build the greeting from `user.nickname`.

3. **`String.to_atom/1` on untrusted input.** Each role string becomes a new atom. Atoms are never garbage-collected, so a feed with many distinct role strings can exhaust the atom table. A missing `role` also raises here, before the `try` begins, so the whole import crashes instead of returning `{:error, :invalid}`. Fix: convert with `String.to_existing_atom/1` and reject unknown values. An explicit list of allowed roles is better still; the list needs to come from the app's role definitions, which were not in the input.

4. **The blanket `rescue _ ->` hides bugs.** Any exception, including a database outage or a typo in this module, is reported as `{:error, :invalid}`. The bad row is silently dropped and the cause is lost. Fix: validate inputs explicitly and let unexpected exceptions raise.

5. **Duplicate check is a race.** `Repo.get_by/2` followed by `Repo.insert/1` lets two concurrent imports insert the same email. Fix: add a unique index on `email` and handle the constraint error from `Repo.insert/1`. The pre-check can stay for a clear error, but it is not the guarantee.

6. **`return_id` changes the return type.** With the option set, success returns a bare integer; otherwise it returns `{:ok, user}`. Callers have to handle two shapes. Fix: return `{:ok, id}` in that case. This changes the public contract, so check callers before merging.

7. **Insert failures lose their reason.** `_ -> {:error, :insert_failed}` drops the changeset that `Repo.insert/1` returns, which holds the validation messages. Fix: keep the changeset in the error so the caller can see why the row failed.

8. **Welcome email runs in an unsupervised process.** `spawn/1` gives no restart and no error report. `Task.start/1` at least logs crashes; `Task.Supervisor.start_child/2` also gives supervision if the app has a supervisor for this.

9. **Control flow is hard to follow.** Four nested `if`/`case` blocks and a dead `is_binary(email)` check (the email is already a string after `String.downcase/1`) make the validation order hard to read. A `with` chain shows the steps in order and returns the first failure.

10. **Noise and small style issues.** Several comments restate the code ("Get the role from params", "send the email"). The `greeting |> (fn ...).()` pipe is harder to read than a string interpolation. There is no `@moduledoc`.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.{Repo, User}

  @max_age 120
  @min_age 18

  @doc """
  Imports one user from `params`.

  Options:

    * `:notify` - send a welcome email (default `false`)
    * `:silent` - suppress the welcome email even when `:notify` is set
    * `:return_id` - return `{:ok, id}` instead of `{:ok, user}`

  Returns `{:ok, user_or_id}` or `{:error, :invalid | :insert_failed}`.
  """
  def import_user(params, opts \\ []) do
    with {:ok, email} <- parse_email(params["email"]),
         {:ok, role} <- parse_role(params["role"]),
         {:ok, age} <- parse_age(params["age"]),
         :ok <- check_min_age(age),
         :ok <- ensure_unique_email(email),
         {:ok, user} <- insert_user(build_user(params, email, role, age)) do
      maybe_notify(user, opts)
      format_result(user, opts)
    end
  end

  defp build_user(params, email, role, age) do
    %User{
      email: email,
      age: age,
      role: role,
      nickname: params["nickname"] || email
    }
  end

  defp parse_email(email) when is_binary(email), do: {:ok, String.downcase(email)}
  defp parse_email(_), do: {:error, :invalid}

  # The provider lowercases addresses before its uniqueness check, so match it here.
  defp parse_role(role) when is_binary(role) do
    {:ok, String.to_existing_atom(role)}
  rescue
    ArgumentError -> {:error, :invalid}
  end

  defp parse_role(_), do: {:error, :invalid}

  defp parse_age(age) when is_integer(age), do: {:ok, min(age, @max_age)}

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {n, ""} -> {:ok, min(n, @max_age)}
      _ -> {:error, :invalid}
    end
  end

  defp parse_age(_), do: {:error, :invalid}

  defp check_min_age(age) when age >= @min_age, do: :ok
  defp check_min_age(_), do: {:error, :invalid}

  defp ensure_unique_email(email) do
    if Repo.get_by(User, email: email), do: {:error, :invalid}, else: :ok
  end

  defp insert_user(user) do
    case Repo.insert(user) do
      {:ok, user} -> {:ok, user}
      {:error, changeset} -> {:error, {:insert_failed, changeset}}
    end
  end

  defp maybe_notify(user, opts) do
    if opts[:notify] && !opts[:silent], do: send_welcome(user)
  end

  defp format_result(user, opts) do
    if opts[:return_id], do: {:ok, user.id}, else: {:ok, user}
  end

  defp send_welcome(user) do
    Task.start(fn -> Mailer.deliver(welcome_email(user)) end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

Notes on the rewrite:

- The insert error now returns `{:error, {:insert_failed, changeset}}`, not `{:error, :insert_failed}`. Callers that match the bare atom will need updating. This is the one place where I changed a return shape beyond `return_id`; revert it if callers depend on the atom.
- `ensure_unique_email/1` is still a pre-check. Finding 5 needs a unique index on `email` in the database and a `unique_constraint(:email)` in the `User` changeset. That is a migration and schema change, not part of this file.
- `Task.start/1` replaces `spawn/1` so crashes are logged. If the app has a `Task.Supervisor`, use `Task.Supervisor.start_child/2` instead.
- The `rescue` in `parse_role/1` is limited to `ArgumentError`, the exception `String.to_existing_atom/1` raises for unknown atoms. The code has not been compiled or run here.
