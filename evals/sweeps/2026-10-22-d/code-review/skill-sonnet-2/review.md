# Review: `Accounts.UserImporter`

## Findings

1. **Convert external strings to atoms with explicit clauses.** `role = String.to_atom(params["role"])` lets input exhaust the atom table, and it raises on a missing `"role"` (`nil`). Fix: `parse_role/1` with one clause per accepted role and an `{:error, {:unknown_role, other}}` clause.
2. **Return tuples for expected failures; don't `try ... rescue _ ->`.** The whole body is wrapped in `rescue _ -> {:error, :invalid}`. That hides real bugs and discards the reason. Fix: use `Integer.parse/1`, match the required keys, and return specific errors (`{:missing_field, key}`, `{:invalid_field, key}`).
3. **Match required keys, with one error per field.** `params["email"] |> String.downcase()` raises on `nil`, and `is_binary(email)` is checked only after `String.downcase/1` has already used it. Fix: `string_field/2` (`Map.fetch` plus an `is_binary` guard) chained with `with`.
4. **Rebinding inside `if` does not escape it.** `if age > 120 do age = 120 end` leaves `age` unchanged, and the compiler warns about it. Fix: `min(age, @max_age)`, with the magic numbers named as attributes (`@min_age`, `@max_age`).
5. **Validate input with a changeset and declare constraints.** The code builds `%User{...}` by hand, then runs `Repo.get_by(...) == nil` before `Repo.insert`. That lookup-then-insert is a race, since two imports can both pass the check. Fix: `cast/3`, `validate_required/2`, `validate_number/3` and `unique_constraint(:email)`. The unique index now decides, and a violation returns `{:error, changeset}`.
6. **Match every expected shape.** `_ -> {:error, :insert_failed}` throws away the changeset. Fix: pass `{:error, %Ecto.Changeset{}}` through.
7. **Use `and`/`not` with booleans.** `is_binary(email) && age >= 18` is replaced by guard/changeset validation; `opts[:notify] && !opts[:silent]` is replaced by finding 8.
8. **Use one option, not overlapping booleans.** `notify`/`silent` can contradict each other. Fix: only `notify: false`, checked with `Keyword.validate!/2` and documented under `## Options`.
9. **One return shape per function.** `return_id: true` returns a bare id, otherwise `{:ok, user}`. Fix: removed. Callers use `{:ok, user}` and read `user.id`.
10. **Supervise processes.** A bare `spawn/1` for the email is unsupervised and its failures are invisible. Fix: `Task.Supervisor.start_child(Accounts.TaskSupervisor, ...)`. The supervisor must be in the application's tree.
11. **Structs don't implement `Access`.** `user[:name]` raises `UndefinedFunctionError` on a `%User{}`. Fix: `user.nickname`, which is always set. `Mailer` is also now aliased as `Accounts.Mailer` (assumed namespace).
12. **Don't pipe into an anonymous function.** `greeting |> (fn ... end).()` is replaced by one interpolated string.
13. **Nesting and length.** Four levels of `if`/`case` become a short `with` pipeline plus small private functions.
14. **Comments and docs.** `# Get the role from params`, `# send the email` and similar restate the code and are removed. `@moduledoc` and `@doc` (with `## Options`) replace the comments above the module and function. The provider comment explains a reason, so it stays, next to the downcase.
15. **Ordering.** `import` comes before `alias`.

Assumptions: `User` has fields `email, age, role, nickname`, allowed roles are `:admin | :member`, and there is a unique index on `email`. Adjust `parse_role/1` to the real roles.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from external CSV/JSON rows.
  """

  import Ecto.Changeset

  alias Accounts.Mailer
  alias Accounts.Repo
  alias Accounts.User

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from string-keyed `params`.

  Requires `"email"`, `"age"` and `"role"`; `"nickname"` defaults to the email.
  Ages above #{@max_age} are clamped to #{@max_age}.

  Returns `{:ok, user}`, `{:error, {:missing_field, key}}`,
  `{:error, {:invalid_field, key}}`, `{:error, {:unknown_role, role}}` or
  `{:error, changeset}` (for example a duplicate email or an age under #{@min_age}).

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, attrs} <- parse_params(params),
         {:ok, user} <- insert_user(attrs) do
      if opts[:notify], do: send_welcome(user)

      {:ok, user}
    end
  end

  defp parse_params(params) do
    with {:ok, email} <- string_field(params, "email"),
         {:ok, age_text} <- string_field(params, "age"),
         {:ok, role_text} <- string_field(params, "role"),
         {:ok, age} <- parse_age(age_text),
         {:ok, role} <- parse_role(role_text) do
      # The provider lowercases addresses before its uniqueness check, so match it here
      email = String.downcase(email)

      {:ok, %{email: email, age: age, role: role, nickname: params["nickname"] || email}}
    end
  end

  defp string_field(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp parse_age(text) do
    case Integer.parse(text) do
      {age, ""} -> {:ok, min(age, @max_age)}
      {_age, _rest} -> {:error, {:invalid_field, "age"}}
      :error -> {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("member"), do: {:ok, :member}
  defp parse_role(other), do: {:error, {:unknown_role, other}}

  defp insert_user(attrs) do
    %User{}
    |> cast(attrs, [:email, :age, :role, :nickname])
    |> validate_required([:email, :age, :role])
    |> validate_number(:age, greater_than_or_equal_to: @min_age)
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
