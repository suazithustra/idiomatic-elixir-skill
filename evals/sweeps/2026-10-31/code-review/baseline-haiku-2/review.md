# Review: `Accounts.UserImporter`

1. **The age cap never runs.** In Elixir, a variable set inside an `if` does not change the variable outside it, so `age = 120` is discarded and users over 120 are saved with their original age. Fix: `min(age, 120)`.

2. **Role names create atoms from input.** `String.to_atom(params["role"])` turns any string into an atom. Atoms are never garbage-collected, so a bad file can exhaust the atom table and crash the VM. It also runs outside the `try`, so a missing role raises. Fix: map a fixed list of known role strings to atoms and reject anything else.

3. **The blanket `rescue _` hides real failures.** Any exception, including a database outage or a typo in the code, becomes `{:error, :invalid}`. Callers cannot tell bad input from broken code. Fix: validate each field explicitly with `with` and let unexpected errors raise.

4. **The `is_binary(email)` check is dead code.** `String.downcase/1` runs first and already raises on `nil` or a non-string, so the check can never be false when reached.

5. **The welcome email reads a field the struct does not have.** `user[:name]` uses the `Access` protocol, which plain structs do not implement, so it raises inside the spawned process. The error is only written to the log and the caller never sees it. The `%User{}` built here sets `nickname`, not `name`, so the fix is to use `user.nickname`. This assumes `nickname` is what the email should show.

6. **Duplicate emails can get through under concurrency.** The code checks `Repo.get_by/2` and then inserts. Two imports of the same address running at the same time can both pass the check. Fix: add a unique index on `email` in the database and handle the constraint error on insert. The check can stay as a fast path.

7. **`return_id` changes the return type.** With the option set, the function returns a bare integer. Otherwise it returns `{:ok, user}`. Callers have to handle both shapes. Fix: give the id-only case its own function, or always return `{:ok, user}` and let the caller read `.id`.

8. **`spawn/1` starts an unsupervised process.** Nothing restarts it or reports its failures beyond the default crash log. The improved code uses `Task.start/1`, which is a small step up. For real retries or failure tracking, use a supervised task or a job queue such as Oban.

9. **Comments repeat the code.** Lines such as "Get the role from params" add nothing. The one comment that explains a reason (the provider lowercases addresses) stays. The module now has a `@moduledoc`.

## Improved code

Assumptions to check:
- The valid roles are `"admin"` and `"member"`. Replace them with the app's real list.
- The welcome email uses `nickname`, since that is the field this module sets.
- Unknown roles and ages under 18 are rejected, as before. Ages over 120 are now capped at 120, as the original code intended.

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports a single user from an external CSV or JSON source.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports one user from `params`.

  Options:
    * `:notify` - send a welcome email (default `false`)
    * `:silent` - suppress the welcome email even if `:notify` is set
    * `:return_id` - return the new user's id instead of `{:ok, user}`
  """
  def import_user(params, opts \\ []) do
    with {:ok, attrs} <- parse_attrs(params),
         :ok <- ensure_unique_email(attrs.email),
         {:ok, user} <- insert_user(attrs) do
      maybe_notify(user, opts)
      format_result(user, opts)
    end
  end

  defp parse_attrs(params) do
    with {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         {:ok, role} <- parse_role(params["role"]) do
      {:ok, %{email: email, age: age, role: role, nickname: params["nickname"] || email}}
    end
  end

  defp parse_email(email) when is_binary(email), do: {:ok, String.downcase(email)}
  defp parse_email(_), do: {:error, :invalid}

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {value, ""} when value >= @min_age -> {:ok, min(value, @max_age)}
      _ -> {:error, :invalid}
    end
  end

  defp parse_age(_), do: {:error, :invalid}

  # Assumed role names. Replace with the app's real list.
  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("member"), do: {:ok, :member}
  defp parse_role(_), do: {:error, :invalid}

  # Fast path only. The unique index on users.email is the real guard against races.
  defp ensure_unique_email(email) do
    if Repo.get_by(User, email: email), do: {:error, :invalid}, else: :ok
  end

  defp insert_user(attrs) do
    case Repo.insert(struct(User, attrs)) do
      {:ok, user} -> {:ok, user}
      {:error, _changeset} -> {:error, :insert_failed}
    end
  end

  defp maybe_notify(user, opts) do
    if opts[:notify] && !opts[:silent], do: send_welcome(user)
  end

  defp format_result(user, opts) do
    if opts[:return_id], do: user.id, else: {:ok, user}
  end

  defp send_welcome(user) do
    Task.start(fn -> Mailer.deliver(welcome_email(user)) end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```
