# Review: `Accounts.UserImporter`

Input: `code-review-input.ex` (57 lines).

## Findings

1. **Outside input creates atoms, and a missing role crashes the function.** Line 8 calls `String.to_atom(params["role"])` before the `try`. Atoms are never garbage collected, so a stream of made-up role names can exhaust the atom table of the Erlang virtual machine (the runtime Elixir runs on). A missing role (`nil`) raises an exception that is not inside the `try`, so the caller gets a crash instead of `{:error, :invalid}`. The fix parses the role with `String.to_existing_atom/1` and returns `{:error, :invalid}` for anything else.

2. **The age cap never takes effect.** Lines 15-17 rebind `age` inside an `if`. Elixir does not carry a variable set inside an `if` back to the outer scope, so `age` stays at its real value. A user aged 150 is saved as 150, and any age above 120 passes the adult check. The fix uses `min(age, 120)` as a value.

3. **The blanket `rescue _` hides bugs.** Lines 42-44 turn every exception into `{:error, :invalid}`. This includes mistakes in the code itself and a missing email. `params["email"] |> String.downcase()` (line 12) runs before the `is_binary/1` check (line 21), so a missing email raises and is swallowed. The fix checks types first, parses explicitly with `Integer.parse/1`, and removes the `try`.

4. **Duplicate check and insert are not atomic.** `Repo.get_by/2` (line 24) and `Repo.insert/1` (line 25) are separate steps. Two imports of the same email that run at the same time can both pass the check. The database should enforce uniqueness with a unique index, and the changeset should map the constraint error to `{:error, :invalid}`. The pre-check is kept in the fix to preserve current behavior. I have not seen the `User` schema or migrations, so I could not confirm whether a unique index exists.

5. **Welcome emails can silently fail.** `user[:name]` (line 53) uses bracket access. Ecto schema structs do not implement the `Access` behavior, so this raises and the email is never sent. The fail is silent because `spawn/1` (line 49) runs the call outside any supervisor. The fix uses `Map.get/2`, which works on structs, and `Task.start/1`, which logs crashes. For production use, a `Task.Supervisor` is the stronger choice. I did not see `Mailer` in the input, so I left its module name unchanged.

6. **The return value depends on an option.** With `return_id: true` the function returns a bare id (line 31). Otherwise it returns `{:ok, user}`. Bad input, a duplicate, and a failed insert all collapse into `:invalid` or `:insert_failed` with no way to tell duplicates apart. The fix keeps this contract so existing callers still work. Changing it to always return `{:ok, _}` and adding a `:duplicate_email` reason should be a separate change, since it affects callers.

7. **Style.** The pipe into an anonymous function (line 55) is harder to read than string interpolation. The `if` used for assignment (lines 15-17) is the cause of finding 2. Comments such as "Get the role from params" restate the code. There is no `@doc` for the public function.

## Improved code

Saved as `check/improved.ex` in this directory. It compiles with stub modules for `Accounts.Repo`, `Accounts.User`, and `Mailer`, and the smoke checks in `check/run.exs` return `{:error, :invalid}` for each bad input. Those checks do not cover the success path against a real database.

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV/JSON source.

  Returns `{:ok, user}` on success, or `{:error, reason}` where `reason` is
  `:invalid` (bad or duplicate input) or `:insert_failed` (the database
  rejected the row).
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports one user from `params`.

  Options:

    * `:notify` - send a welcome email (default `false`)
    * `:silent` - suppress the welcome email even when `:notify` is set
    * `:return_id` - return the new user's id instead of `{:ok, user}`
  """
  def import_user(params, opts \\ []) do
    with {:ok, email} <- normalize_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         :ok <- check_adult(age),
         {:ok, role} <- parse_role(params["role"]),
         :ok <- check_unique_email(email),
         {:ok, user} <- insert_user(email, age, role, params["nickname"]) do
      after_insert(user, opts)
    end
  end

  defp normalize_email(email) when is_binary(email), do: {:ok, String.downcase(email)}
  defp normalize_email(_), do: {:error, :invalid}

  # Ages above the maximum are capped rather than rejected.
  defp parse_age(age) when is_integer(age), do: {:ok, min(age, @max_age)}

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {n, ""} -> {:ok, min(n, @max_age)}
      _ -> {:error, :invalid}
    end
  end

  defp parse_age(_), do: {:error, :invalid}

  defp check_adult(age) when age >= @min_age, do: :ok
  defp check_adult(_), do: {:error, :invalid}

  # Only existing atoms are accepted, so outside input cannot grow the atom table.
  defp parse_role(role) when is_binary(role) do
    {:ok, String.to_existing_atom(role)}
  rescue
    ArgumentError -> {:error, :invalid}
  end

  defp parse_role(_), do: {:error, :invalid}

  defp check_unique_email(email) do
    if Repo.get_by(User, email: email), do: {:error, :invalid}, else: :ok
  end

  defp insert_user(email, age, role, nickname) do
    user = %User{email: email, age: age, role: role, nickname: nickname || email}

    case Repo.insert(user) do
      {:ok, user} -> {:ok, user}
      {:error, _changeset} -> {:error, :insert_failed}
    end
  end

  defp after_insert(user, opts) do
    if opts[:notify] && !opts[:silent], do: send_welcome(user)

    if opts[:return_id], do: user.id, else: {:ok, user}
  end

  defp send_welcome(user) do
    Task.start(fn -> Mailer.deliver(welcome_email(user)) end)
  end

  # Map.get/2 works on Ecto structs; bracket access does not, since they do not implement Access.
  defp welcome_email(user) do
    name = Map.get(user, :name) || "there"
    "Hi #{name}, welcome! Enjoy your account."
  end
end
```

## Notes on the fix

- `parse_role/1` accepts only role atoms that already exist in the loaded code. A role defined only in the database, and never referenced in code, is now rejected. I checked this in the smoke run: an unknown role string returns `{:error, :invalid}`.
- The compile output includes two type warnings. Both come from the stub `Repo` module, which always returns a fixed result. They do not apply to the real `Repo`.
