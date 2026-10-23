# Review: `Accounts.UserImporter`

## Findings

1. **Clamp never applies (bug).** `if age > 120 do age = 120 end` rebinds `age` inside the `if`. Elixir does not leak that binding out, so `age` stays at its original value (e.g. 150) and the clamp is dead code.
2. **Atom leak from untrusted input (security/bug).** `String.to_atom(params["role"])` creates a new atom per distinct input and atoms are never garbage collected, so the VM can run out of atoms. It also runs outside the `try`, so a `nil` role raises.
3. **Blanket `try/rescue` hides bugs.** `rescue _ -> {:error, :invalid}` turns every exception into the same error, including programming errors and database failures. Validation should be explicit so real faults crash and get reported.
4. **Catch-all in `case Repo.insert/1`.** `_ -> {:error, :insert_failed}` matches anything. Match `{:error, _changeset}` so an unexpected return shape fails loudly.
5. **`String.to_integer/1` raises on bad input.** Non-numeric strings, `nil`, and integer values all raise and are rescued into `:invalid`. `Integer.parse/1` returns a tuple and makes the failure path explicit.
6. **`String.downcase/1` on `nil` raises, and `is_binary(email)` is checked too late.** The type check should come before the transform, and the `is_binary` check is redundant once it does.
7. **`user[:name]` on a struct raises.** `User` is a struct and does not implement `Access`, so `user[:name]` raises `UndefinedFunctionError`. The welcome email therefore never gets sent. `Map.get/2` works on structs and keeps the `"there"` fallback.
8. **Unsupervised `spawn/1` for email delivery.** Crashes are not reported and the process is not tracked. `Task.start/1` gives crash reporting; a `Task.Supervisor` is better if the app has one.
9. **Needless indirection in `welcome_email/1`.** `greeting |> (fn ...).()` is an anonymous function applied through a pipe. String interpolation says the same thing.
10. **Inconsistent return type.** With `return_id: true` the function returns a bare integer on success and `{:error, _}` on failure. Callers have to handle two success shapes. Left as-is to preserve the API, but flagged.
11. **Narrating comments.** `# Get the role from params`, `# send the email` and similar restate the code. The module comment belongs in `@moduledoc`, and the provider comment on the email lowercasing is worth keeping because it explains a non-obvious reason.
12. **Mixed boolean operators.** `&&`/`!` are used with values that may be `nil` (`opts[:notify]`). That is correct and should stay, since `and`/`not` raise on non-booleans; the code is left unchanged on this point.
13. **Behavior change to note.** Removing the `try/rescue` means a database exception from `Repo.insert/1` now propagates instead of returning `{:error, :invalid}`. This is intentional, but callers that relied on it need to know.
14. **Assumption on roles.** `parse_role/1` uses `String.to_existing_atom/1`, which only accepts atoms already loaded in the VM. That bounds the atom table but still accepts any existing atom, such as `:system`. An explicit allowlist, or an `Ecto.Enum` field, is the stronger fix. The valid role set is not visible in this file, so it is not hard-coded here.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV/JSON source.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from the given params.

  Returns `{:ok, user}`, or the new user's id when `return_id: true` is passed.
  Returns `{:error, :invalid}` for bad input and `{:error, :insert_failed}` when
  the insert is rejected.
  """
  def import_user(params, opts \\ []) do
    with {:ok, role} <- parse_role(params["role"]),
         {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         :ok <- check_adult(age) do
      user = %User{
        email: email,
        age: min(age, @max_age),
        role: role,
        nickname: params["nickname"] || email
      }

      insert_user(user, opts)
    else
      _ -> {:error, :invalid}
    end
  end

  defp insert_user(user, opts) do
    case Repo.insert(user) do
      {:ok, user} ->
        if opts[:notify] && !opts[:silent], do: send_welcome(user)

        if opts[:return_id], do: user.id, else: {:ok, user}

      {:error, _changeset} ->
        {:error, :insert_failed}
    end
  end

  # The provider lowercases addresses before its uniqueness check, so match it here
  defp parse_email(email) when is_binary(email), do: {:ok, String.downcase(email)}
  defp parse_email(_), do: {:error, :invalid}

  defp parse_age(age) when is_integer(age), do: {:ok, age}

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {age, ""} -> {:ok, age}
      _ -> {:error, :invalid}
    end
  end

  defp parse_age(_), do: {:error, :invalid}

  defp check_adult(age) when age >= @min_age, do: :ok
  defp check_adult(_), do: {:error, :invalid}

  # Only atoms already loaded in the VM are accepted, so input cannot grow the atom table
  defp parse_role(role) when is_binary(role) do
    {:ok, String.to_existing_atom(role)}
  rescue
    ArgumentError -> {:error, :invalid}
  end

  defp parse_role(_), do: {:error, :invalid}

  defp send_welcome(user) do
    Task.start(fn -> Mailer.deliver(welcome_email(user)) end)
  end

  defp welcome_email(user) do
    name = Map.get(user, :name) || "there"

    "Hi #{name}, welcome! Enjoy your account."
  end
end
```

Notes on the rewrite:

- The `try/rescue` is gone. `parse_role/1` keeps a narrow `rescue` for `ArgumentError` only, because `String.to_existing_atom/1` signals an unknown atom that way.
- The age clamp now uses `min/2`, so it actually applies. The adult check runs on the unclamped age, which gives the same result as before.
- `Task.start/1` replaces `spawn/1`. If the app has a `Task.Supervisor`, use `Task.Supervisor.start_child/2` with it.
- The return shape for `return_id: true` is unchanged (finding 10). Changing it is an API decision for the callers.
- Not compiled or run here; this is a read-through of the code.
