# Review: `Accounts.UserImporter`

## Findings

1. **The age cap does nothing.** Ages over 120 are meant to be capped at 120, but the `if` block rebinds `age` inside its own scope, so the outer value stays at 150. Elixir reports this as an unused variable (verified on Elixir 1.20.3). The fix is `min(age, 120)` computed as a value, not a rebinding inside `if`.

2. **The welcome email is never sent.** `welcome_email/1` reads `user[:name]`, but `%User{}` is a struct, and structs do not support bracket access (verified: it raises). The error happens inside a `spawn/1` process, so nothing reports it and the caller never sees it. The fix is to use `user.nickname`, which is always set (it defaults to the email), and to start the job with `Task.start/1` so crashes are logged.

3. **Role strings become atoms without limit.** `String.to_atom/1` runs on untrusted input from the import file. Atoms are never garbage-collected, so a file with many distinct role strings grows the VM's atom table until it crashes. A missing role also raises before the `try` block, so it is not caught. The fix is a fixed map from known role strings to atoms, with anything else returned as `{:error, :invalid}`.

4. **A blanket `rescue` hides real errors.** `rescue _ -> {:error, :invalid}` turns every exception into "invalid input", including database connection failures and bugs in this module. Those problems then look like bad rows in the source file. The fix is explicit parsing (`Integer.parse/1`, `Map.fetch/2`) inside a `with`, and no `rescue`. Database exceptions now propagate, which is the correct behavior for a caller to see.

5. **The email type check runs too late.** `String.downcase/1` runs first and raises on `nil`, and the `rescue` catches that. The later `is_binary(email)` check can never fail. The fix is to check the type before downcasing.

6. **Non-string ages are rejected, including from JSON.** The module accepts JSON sources, where ages usually arrive as integers. `String.to_integer/1` raises on an integer, so every JSON row with a numeric age is rejected. The fix accepts both integers and numeric strings. This is a behavior change for JSON input.

7. **`:return_id` changes the return type.** With that option the function returns a bare id, and without it returns `{:ok, user}`. Callers have to know which option they passed to read the result. I kept the behavior because callers may depend on it, and documented it in `@doc`. Splitting it into a separate function is the cleaner long-term fix.

8. **The insert error is discarded.** On failure, `Repo.insert/1` returns a changeset with the reason (for example, a duplicate email). The original code throws it away and returns `:insert_failed`. The new code still returns `:insert_failed`, but the error is now matched explicitly so the reason can be logged later.

9. **Smaller points.** `welcome_email/1` pipes into an anonymous function to add a suffix, which is harder to read than one string. The comments restate the code. The module has no `@moduledoc`, `@doc`, or `@spec`. `Mailer.deliver/1` receives a plain string; check that the Mailer API accepts a string and not an email struct. I could not check this because the Mailer module was not provided.

## Behavior changes to confirm

- Roles not in the map (`@roles`) are now rejected. The list `admin` and `member` is a placeholder; replace it with the roles your schema uses.
- Integer ages from JSON are now accepted.
- Database exceptions now raise to the caller instead of returning `{:error, :invalid}`.

## Improved code

Compiled and run with stub modules for `Accounts.Repo`, `Accounts.User`, and `Mailer` on Elixir 1.20.3. Checked: age cap, under-18 rejection, unknown and missing role, integer age, nil email, database error, `:return_id`, and the welcome email text.

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  # Maps role strings from the source to known atoms. Replace the list
  # with the roles your User schema accepts.
  @roles %{"admin" => :admin, "member" => :member}

  @doc """
  Imports one user from `params`.

  Returns `{:ok, user}`, or the new user's id when `:return_id` is set.
  Returns `{:error, :invalid}` for bad input and `{:error, :insert_failed}`
  when the database rejects the row.

  Options:

    * `:notify` - send a welcome email (default: `false`)
    * `:silent` - suppress the welcome email even when `:notify` is set
    * `:return_id` - return the new id instead of `{:ok, user}`
  """
  def import_user(params, opts \\ []) do
    with {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         {:ok, role} <- Map.fetch(@roles, params["role"]) do
      user = %User{
        email: email,
        age: age,
        role: role,
        nickname: params["nickname"] || email
      }

      insert(user, opts)
    else
      _ -> {:error, :invalid}
    end
  end

  defp parse_email(email) when is_binary(email), do: {:ok, String.downcase(email)}
  defp parse_email(_), do: :error

  defp parse_age(age) when is_integer(age), do: check_age(age)

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {value, ""} -> check_age(value)
      _ -> :error
    end
  end

  defp parse_age(_), do: :error

  # Ages above the maximum are capped, not rejected.
  defp check_age(age) when age >= @min_age, do: {:ok, min(age, @max_age)}
  defp check_age(_), do: :error

  defp insert(user, opts) do
    case Repo.insert(user) do
      {:ok, user} ->
        if opts[:notify] && !opts[:silent], do: send_welcome(user)

        if opts[:return_id], do: user.id, else: {:ok, user}

      {:error, _changeset} ->
        {:error, :insert_failed}
    end
  end

  defp send_welcome(user) do
    # Task.start/1 logs a crash; the earlier spawn/1 failed silently.
    Task.start(fn -> Mailer.deliver(welcome_email(user)) end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```
