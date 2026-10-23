# Review: `Accounts.UserImporter`

## Findings

1. **Age cap never takes effect (correctness).** Inside `if age > 120 do age = 120 end`, the rebinding is scoped to the `if` block. The outer `age` stays at the original value, so an input of `150` is stored as `150`. Fix: `age = min(age, 120)`.

2. **Atom leak from untrusted input (security / correctness).** `String.to_atom(params["role"])` creates a new atom for every distinct role string, and atoms are never garbage collected. It also raises on `nil`, and that raise happens outside the `try`, so it is not rescued. Validate against a fixed allowlist instead.

3. **Blanket `rescue _ ->` hides bugs (correctness / maintainability).** Any exception becomes `{:error, :invalid}`, including database outages and programming errors. Parse and validate explicitly with `with` and `Integer.parse/1`, and let truly unexpected failures raise.

4. **Nested conditionals instead of a `with` pipeline (idiom).** Four levels of `if`/`case`/`else` make the happy path hard to follow. Each validation step should be a clause in one `with`.

5. **Validation order is wrong (correctness / clarity).** `String.downcase/1` runs before the `is_binary(email)` check. A `nil` email crashes inside `downcase` and is saved only by the rescue. The check is also redundant once it is reached.

6. **Check-then-insert race (correctness).** `Repo.get_by/2` followed by `Repo.insert/1` can create duplicates under concurrent imports. The database unique index is the real guard. Add `unique_constraint(:email)` in the changeset and map the constraint error. This review does not change that path, since it depends on `User.changeset/2`, which was not provided.

7. **Insert errors are discarded (maintainability).** `_ -> {:error, :insert_failed}` drops the changeset, so callers cannot tell why the insert failed. Return `{:error, changeset}` if the caller can accept it. The improved code keeps `:insert_failed` to preserve the current contract.

8. **Mixed return types (API design).** With `return_id: true` the function returns a bare id, otherwise `{:ok, user}`. Callers must special-case the option. Consider always returning `{:ok, user}` and letting callers read `.id`. The improved code keeps the behavior and flags it.

9. **Unsupervised `spawn/1` for email delivery (reliability).** Crashes in `Mailer.deliver/1` are silent. Prefer `Task.Supervisor.start_child/2` under a named supervisor. `Task.start/1` is the minimum improvement, and the improved code uses it.

10. **`user[:name]` on a struct (correctness).** `User` is a struct, and structs do not implement the `Access` behaviour, so `user[:name]` raises `UndefinedFunctionError`. The struct built here has no `name` field either. Use `user.nickname`, which is always set because it falls back to the email.

11. **Pointless pipe into an anonymous function (idiom).** `greeting |> (fn text -> ... end).()` is `greeting <> " Enjoy your account."`. A single interpolated string is clearer.

12. **Boolean operators (idiom).** `&&` and `!` work on any truthy value. Use `and` and `not` when the operands are booleans, as they are here.

13. **Noisy comments and missing docs (style).** Comments such as "Get the role from params" restate the code. The public function has no `@doc`, and the option semantics (`:notify`, `:silent`, `:return_id`) are undocumented. Use `@moduledoc` and `@doc`.

14. **Module-level comment is a moduledoc in disguise (style).** `# This module imports...` should be `@moduledoc`.

## Behavior changes in the improved code

- Exceptions from `Repo` or `Mailer` now propagate instead of returning `{:error, :invalid}`. This is intentional, but callers that relied on the blanket rescue need to be checked.
- Roles must match the `@roles` allowlist. Any other value returns `{:error, :invalid}`. Update `@roles` to the real role set.
- Age values such as `" 25"` or `"25.0"` are rejected by `Integer.parse/1` with a full-string match, as they were by `String.to_integer/1`.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV/JSON source.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120
  # Replace with the application's real role set.
  @roles [:admin, :member]

  @doc """
  Imports a single user from `params`.

  Returns `{:ok, user}`, or `{:error, :invalid}` when validation fails, or
  `{:error, :insert_failed}` when the insert is rejected.

  ## Options

    * `:notify` - send a welcome email after a successful insert (default `false`)
    * `:silent` - suppress the welcome email even when `:notify` is set
    * `:return_id` - return the new user's id instead of `{:ok, user}`
  """
  def import_user(params, opts \\ []) do
    with {:ok, role} <- parse_role(params["role"]),
         {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         :ok <- ensure_unique_email(email) do
      user = %User{
        email: email,
        age: age,
        role: role,
        nickname: params["nickname"] || email
      }

      insert(user, opts)
    else
      :error -> {:error, :invalid}
    end
  end

  defp insert(user, opts) do
    case Repo.insert(user) do
      {:ok, user} ->
        if opts[:notify] and not opts[:silent], do: send_welcome(user)

        if opts[:return_id], do: user.id, else: {:ok, user}

      {:error, _changeset} ->
        {:error, :insert_failed}
    end
  end

  defp parse_role(role) when is_binary(role) do
    case Enum.find(@roles, &(Atom.to_string(&1) == role)) do
      nil -> :error
      role -> {:ok, role}
    end
  end

  defp parse_role(_), do: :error

  defp parse_email(email) when is_binary(email), do: {:ok, String.downcase(email)}
  defp parse_email(_), do: :error

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {age, ""} when age >= @min_age -> {:ok, min(age, @max_age)}
      _ -> :error
    end
  end

  defp parse_age(_), do: :error

  defp ensure_unique_email(email) do
    if Repo.get_by(User, email: email), do: :error, else: :ok
  end

  defp send_welcome(user) do
    Task.start(fn -> Mailer.deliver(welcome_email(user)) end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```
