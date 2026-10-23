# Review: Accounts.UserImporter

## Findings

1. **Atoms from external strings**: `role = String.to_atom(params["role"])`. Atoms are never garbage-collected, so user input can exhaust the atom table. It also raises on a missing role. Fix: explicit `role_atom/1` clauses returning `{:ok, atom}` or `{:error, {:invalid_field, "role"}}`.
2. **`try/rescue _` around the whole function**: `rescue _ -> {:error, :invalid}`. It hides real bugs behind one error. Fix: non-raising `Integer.parse/1` and pattern matches; no `rescue`.
3. **Rebinding inside `if` does not escape**: `if age > 120 do age = 120 end`. The clamp never happens. Fix: `min(age, @max_age)`.
4. **Raising conversions / `params["key"]` for required keys**: `String.to_integer(params["age"])`, `params["email"] |> String.downcase()`. Missing or malformed input raises or yields `nil`. Fix: `string_field/2` and `parse_age/1` chained with `with`, returning `{:missing_field, key}` / `{:invalid_field, key}`.
5. **Dead check**: `is_binary(email)` runs after `String.downcase(email)`, which already raised for non-binaries. Fix: validate in `string_field/2` first.
6. **`&&` / `!` on booleans**: `is_binary(email) && age >= 18`. Now a guard in `validate_age/1`.
7. **Overlapping boolean options**: `opts[:notify] && !opts[:silent]`. Fix: single `notify:` option, `Keyword.validate!/2`, documented under `## Options`.
8. **Option changes the return shape**: `if opts[:return_id], do: user.id, else: {:ok, user}`. Fix: removed; always `{:ok, user}`.
9. **`_ ->` catch-all on `Repo.insert`**: turns every failure into `:insert_failed`. Fix: match `{:error, changeset}` and return it.
10. **Access on a struct**: `user[:name]` raises `UndefinedFunctionError`. Fix: `user.nickname` (assumes `User` has no `:name` field).
11. **Bare `spawn/1` capturing the whole `user`**: unsupervised and copies the struct. Fix: `Task.Supervisor.start_child(Accounts.TaskSupervisor, ...)` capturing only the built email. Needs `{Task.Supervisor, name: Accounts.TaskSupervisor}` in the supervision tree.
12. **Pipe into anonymous fn**: `greeting |> (fn text -> ... end).()`. Fix: one string expression.
13. **Comments and docs**: "This module imports...", "Get the role...", "send the email" restate code, and the function doc is a comment. Fix: `@moduledoc` / `@doc`. Kept the "provider lowercases addresses" comment because it explains why. Magic numbers became `@min_age` / `@max_age`.
14. **Single-step pipe**: `params["email"] |> String.downcase()` becomes `String.downcase(email)`.

## Not applied (assumptions)

- Ecto: hand-building `%User{}` and calling `Repo.insert/1` skips validation and raises on constraint violations. The better fix is `User.changeset/2` (`cast`, `validate_required`, `validate_number`, `unique_constraint`). `User` is not shown, so I kept the struct insert and the field checks here.
- The allowed roles (`:admin`, `:editor`, `:member`) are a guess; replace with the real set (or `Ecto.Enum`).
- I ran `mix format` on the file but could not compile or run it (the sandbox blocked the shell commands).

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from string-keyed params (CSV/JSON rows).
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from string-keyed `params`.

  Requires the `"email"`, `"age"`, and `"role"` keys. Ages above 120 are
  clamped to 120.

  Returns `{:ok, user}`, `{:error, {:missing_field, key}}`,
  `{:error, {:invalid_field, key}}`, or `{:error, changeset}` when the insert fails.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, email} <- string_field(params, "email"),
         {:ok, age} <- parse_age(params),
         {:ok, role} <- parse_role(params),
         {:ok, user} <- insert_user(email, age, role, params["nickname"]) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  defp string_field(params, key) do
    case params do
      %{^key => value} when is_binary(value) -> {:ok, value}
      %{^key => _value} -> {:error, {:invalid_field, key}}
      %{} -> {:error, {:missing_field, key}}
    end
  end

  defp parse_age(params) do
    with {:ok, text} <- string_field(params, "age"),
         {:ok, age} <- parse_integer(text) do
      validate_age(age)
    end
  end

  defp parse_integer(text) do
    case Integer.parse(text) do
      {age, ""} -> {:ok, age}
      {_age, _rest} -> {:error, {:invalid_field, "age"}}
      :error -> {:error, {:invalid_field, "age"}}
    end
  end

  defp validate_age(age) when age >= @min_age, do: {:ok, min(age, @max_age)}
  defp validate_age(_age), do: {:error, {:invalid_field, "age"}}

  defp parse_role(params) do
    with {:ok, text} <- string_field(params, "role"),
         {:ok, role} <- role_atom(text) do
      {:ok, role}
    end
  end

  defp role_atom("admin"), do: {:ok, :admin}
  defp role_atom("editor"), do: {:ok, :editor}
  defp role_atom("member"), do: {:ok, :member}
  defp role_atom(_other), do: {:error, {:invalid_field, "role"}}

  defp insert_user(email, age, role, nickname) do
    # The provider lowercases addresses before its uniqueness check, so match it here
    email = String.downcase(email)
    user = %User{email: email, age: age, role: role, nickname: nickname || email}

    case Repo.insert(user) do
      {:ok, user} -> {:ok, user}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp send_welcome(user) do
    email = welcome_email(user.nickname)

    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn ->
      Mailer.deliver(email)
    end)
  end

  defp welcome_email(nickname) do
    "Hi " <> nickname <> ", welcome! Enjoy your account."
  end
end
```
