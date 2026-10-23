# Review: `Accounts.UserImporter`

## Findings (most severe first)

1. **The age clamp never runs.** `if age > 120 do age = 120 end` rebinds `age` inside the `if`. Since Elixir 1.7 that binding does not escape the `if`, so the outer `age` stays unchanged and values above 120 are stored as-is. Fix: `min(age, @max_age)` in a value-returning function.

2. **`String.to_atom/1` on untrusted input.** `params["role"]` comes from an external file. Each distinct value creates a new atom, and atoms are never garbage collected, so this can exhaust the atom table. It also sits outside the `try`, so a `nil` role raises `FunctionClauseError` straight out of the function. Fix: map known role strings to atoms explicitly and return `{:error, :invalid}` for anything else.

3. **The blanket `rescue _ -> {:error, :invalid}` hides bugs.** Any exception, including a database outage, a bad config, or a programming error, is reported as "invalid input". Parsing failures should be handled explicitly, and the rescue should go.

4. **The insert `case` discards the reason.** `_ -> {:error, :insert_failed}` drops the changeset, so callers and logs cannot see why the insert failed.

5. **Check-then-insert is a race.** `Repo.get_by/2` followed by `Repo.insert/1` can admit two concurrent imports of the same email. The database unique index is the real guard. The insert error path should handle the constraint violation rather than rely on the pre-check.

6. **`welcome_email/1` probably raises.** `user[:name]` uses the `Access` behaviour, which structs do not implement, so this raises at runtime. Even with `Map.get/2`, the `User` struct may have no `:name` field. This needs checking against the schema. The rewrite uses `user.nickname`, which is set in this module; confirm that is the intended greeting name.

7. **Return type depends on an option.** With `return_id: true` the success value is a bare integer, while errors are `{:error, _}` tuples and the default success is `{:ok, user}`. Callers must special-case the option. The rewrite keeps this contract, but it is worth changing to a consistent `{:ok, id}` or `{:ok, user}` if callers allow.

8. **`spawn/1` is unsupervised.** The welcome email runs in a process nothing monitors, so crashes are silent and the process is not linked to anything. Use a supervised task (`Task.Supervisor.start_child/2`). The rewrite assumes an `Accounts.TaskSupervisor` exists in the application tree; confirm before merging.

9. **Validation order is wrong.** `String.downcase(params["email"])` runs before the `is_binary/1` check. A `nil` email raises, the blanket rescue catches it, and the `is_binary` check is dead code.

10. **`String.to_integer/1` is brittle.** It raises on `nil`, non-numeric strings, and integers (for example from JSON sources). `Integer.parse/1` returns a result the caller can match on.

11. **Boolean operators.** `&&` with a non-boolean left side is fine here, but `and` would be wrong in other places, and the mixed `&&`/`!` in `maybe_notify` reads poorly. Keep `&&` where values may be `nil`; it is correct as written.

12. **Style.** The comments restate the code ("Get the role from params", "send the email"), which the guidelines discourage, and the module has no `@moduledoc`/`@doc`. The `welcome_email/1` pipe into an anonymous function is more complicated than string interpolation. The nested `if`/`else` chain reads better as a `with`.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV/JSON source.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  # Must match the role values the User schema accepts.
  @roles %{"admin" => :admin, "member" => :member}

  @doc """
  Imports a single user from the given params.

  Options:

    * `:notify` - send a welcome email (unless `:silent` is set)
    * `:silent` - suppress the welcome email
    * `:return_id` - return the new user's id instead of `{:ok, user}`

  Note: `:return_id` changes the success value to a bare id, which is kept
  for existing callers. Errors are always `{:error, reason}`.
  """
  def import_user(params, opts \\ []) do
    with {:ok, role} <- parse_role(params["role"]),
         {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         :ok <- ensure_unique_email(email),
         {:ok, user} <- insert_user(email, age, role, params["nickname"]) do
      maybe_notify(user, opts)

      if opts[:return_id], do: user.id, else: {:ok, user}
    end
  end

  defp parse_role(role) do
    case Map.fetch(@roles, role) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, :invalid}
    end
  end

  # The provider lowercases addresses before its uniqueness check, so match it here.
  defp parse_email(email) when is_binary(email), do: {:ok, String.downcase(email)}
  defp parse_email(_email), do: {:error, :invalid}

  defp parse_age(age) when is_integer(age) and age >= @min_age do
    {:ok, min(age, @max_age)}
  end

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {age, ""} -> parse_age(age)
      _ -> {:error, :invalid}
    end
  end

  defp parse_age(_age), do: {:error, :invalid}

  defp ensure_unique_email(email) do
    if Repo.get_by(User, email: email), do: {:error, :invalid}, else: :ok
  end

  defp insert_user(email, age, role, nickname) do
    attrs = %{email: email, age: age, role: role, nickname: nickname || email}

    case Repo.insert(struct!(User, attrs)) do
      {:ok, user} -> {:ok, user}
      {:error, _changeset} -> {:error, :insert_failed}
    end
  end

  defp maybe_notify(user, opts) do
    if opts[:notify] && !opts[:silent], do: send_welcome(user)
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

## Notes on the rewrite

- Behaviour changes to confirm: ages above 120 are now clamped (the original intended this); integer ages are accepted; the welcome greeting uses `nickname` instead of a non-existent `name`; welcome emails run under a `Task.Supervisor`.
- The unique-email pre-check is kept for the same `{:error, :invalid}` result. For a fully race-free import, rely on the unique index and map the constraint error to `{:error, :invalid}` in `insert_user/4`.
- Role whitelist assumes `"admin"` and `"member"` are the only valid roles; replace `@roles` with the schema's real values.
- Not compiled or run here; the code was checked by reading only.
