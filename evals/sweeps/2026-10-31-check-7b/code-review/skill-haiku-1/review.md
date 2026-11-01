# Review: `Accounts.UserImporter`

Rules are from `SKILL.md`. Reference files read because the code triggers them: `references/ecto-phoenix.md`, `references/processes.md`, `references/library-design.md`.

## Findings

1. `age = 120` never takes effect. In `if age > 120 do age = 120 end`, a variable set inside `if` does not leave the block, so ages above 120 are stored unchanged. Fix: `age = min(age, @max_age)`. Rule: "Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it".

2. `role = String.to_atom(params["role"])` turns external input into an atom (a named constant). Atoms are never freed and the VM (virtual machine) has a fixed limit on them, so crafted input can crash the node. A missing role also raises here, outside the `try`. Fix: a `parse_role/1` with one clause per accepted role and a final error clause. Rule: "Convert external strings to atoms with explicit clauses".

3. `rescue _ -> {:error, :invalid}` turns every exception into the same error, including database failures and bugs. Fix: remove the `try` and use non-raising calls (`Integer.parse/1`, `Map.fetch/2`), so only real bugs raise. Rule: "never `rescue _ ->` around a whole function".

4. Every failure returns `{:error, :invalid}`. A missing email, a bad age, an age under 18 and a duplicate email all look the same to the caller. Fix: a distinct reason for each: `{:missing_field, key}`, `{:invalid_field, key}`, `:too_young`, and the changeset for a duplicate. Rule: "a caller cannot tell a missing field from a bad number when both return `{:error, :invalid}`".

5. `user[:name]` raises `UndefinedFunctionError`, because `%User{}` is a struct and structs do not implement `Access`. The error happens inside the spawned process, so no welcome email is sent and nothing reports it. Fix: `user.nickname`, which import always sets. Rule: "Structs do not implement `Access`".

6. `spawn(fn -> Mailer.deliver(welcome_email(user)) end)` starts a process that no supervisor watches, so a failed delivery goes nowhere. Fix: `Task.Supervisor.start_child/2` under `Accounts.TaskSupervisor`. Rule: processes.md, "Supervise every long-lived process", and the table row "Fire-and-forget work | `Task.Supervisor.start_child/2`".

7. `Repo.get_by(User, email: email) == nil` followed by `Repo.insert(user)` checks for duplicates by hand. Two imports of the same email can both pass the check, and the raw struct is inserted without validation. Fix: a changeset with `unique_constraint(:email)` and a unique index on the column; a duplicate then returns `{:error, changeset}`. Rule: ecto-phoenix.md, "Declare database constraints in the changeset (`unique_constraint/3`...)".

8. `_ -> {:error, :insert_failed}` drops the reason the insert gave. Fix: match `{:error, changeset}` and pass it through. Rule: "Match every expected shape and let unexpected ones crash".

9. `if opts[:return_id], do: user.id, else: {:ok, user}` makes one function return either a bare integer or a tuple. Fix: `import_user/2` always returns `{:ok, user}`, and a separate `import_user_id/2` returns `{:ok, id}`. Rule: "Give each function one return shape".

10. `opts[:notify] && !opts[:silent]` uses two booleans where one is enough. `silent` has no effect unless `notify` is set, so it adds nothing. Fix: keep `notify: true` and drop `silent`. Rule: "Two booleans overlap when one overrides the other or some combinations make no sense".

11. The body nests `if`, `case` and `if` four levels deep, with each step inline. Fix: a `with` over small private functions, one per step, each returning `{:ok, value}` or `{:error, reason}`. Rule: "Chain fallible steps with `with`; normalize each step's error in a small private function".

12. `if is_binary(email) && age >= 18` joins two booleans with `&&`. Fix: `email` is now checked by `string_field/2`, and the age check is its own step, so the `&&` is removed. Where a boolean check remains, use `and`. Rule: "Use `and`, `or`, `not` when the operands are booleans".

13. `params["email"] |> String.downcase()` pipes a single step, and `greeting |> (fn text -> text <> " Enjoy your account." end).()` pipes into an anonymous function. Fix: `String.downcase(...)` and one interpolated string. Rule: "Do not pipe a single step" and "Do not pipe into an anonymous function call".

14. `18` and `120` appear inline as magic numbers. Fix: `@min_age 18` and `@max_age 120`. Rule: "Name magic numbers with module attributes".

15. Documentation sits in comments. `# This module imports...` should be `@moduledoc` and `# Import a single user...` should be `@doc`. `# Get the role from params` and `# send the email` restate the code, so delete them. The public function has no `@spec` and accepts any value as `params`. Fix: add `@moduledoc`, `@doc`, `@spec` and a `when is_map(params)` guard. Keep `# The provider lowercases addresses...`, because it explains a reason. Rule: "Comments explain why; documentation goes in `@moduledoc` and `@doc`", and library-design.md, "Give every public function a `@spec`".

## Improved version

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV (comma-separated values) or JSON (JavaScript Object Notation) source.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports one user from string-keyed params.

  Returns `{:ok, user}` or `{:error, reason}`. An age above 120 is stored as 120.

  ## Options

    * `:notify` - sends a welcome email when `true`. Defaults to no email.
  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, term()}
  def import_user(params, opts \\ []) when is_map(params) do
    with {:ok, attrs} <- parse_attrs(params),
         :ok <- check_adult(attrs.age),
         {:ok, user} <- insert_user(attrs) do
      maybe_send_welcome(user, opts[:notify])
      {:ok, user}
    end
  end

  @doc """
  Like `import_user/2`, but returns `{:ok, id}` with the new user's ID.
  """
  @spec import_user_id(map(), keyword()) :: {:ok, integer()} | {:error, term()}
  def import_user_id(params, opts \\ []) do
    with {:ok, user} <- import_user(params, opts) do
      {:ok, user.id}
    end
  end

  defp parse_attrs(params) do
    with {:ok, email} <- string_field(params, "email"),
         {:ok, role_name} <- string_field(params, "role"),
         {:ok, role} <- parse_role(role_name),
         {:ok, age} <- parse_age(params) do
      email = String.downcase(email)

      {:ok, %{email: email, role: role, age: age, nickname: params["nickname"] || email}}
    end
  end

  defp check_adult(age) when age >= @min_age, do: :ok
  defp check_adult(_age), do: {:error, :too_young}

  defp insert_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp maybe_send_welcome(user, true), do: send_welcome(user)
  defp maybe_send_welcome(_user, _notify), do: :ok

  defp send_welcome(user) do
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn ->
      Mailer.deliver(welcome_email(user))
    end)
  end

  defp welcome_email(user), do: "Hi #{user.nickname}, welcome! Enjoy your account."

  defp string_field(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp parse_age(params) do
    with {:ok, text} <- string_field(params, "age"),
         {:ok, age} <- parse_integer(text, "age") do
      {:ok, min(age, @max_age)}
    end
  end

  defp parse_integer(text, key) do
    case Integer.parse(text) do
      {integer, ""} -> {:ok, integer}
      {_integer, _rest} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:invalid_field, key}}
    end
  end

  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("editor"), do: {:ok, :editor}
  defp parse_role("viewer"), do: {:ok, :viewer}
  defp parse_role(other), do: {:error, {:unknown_role, other}}
end
```

## Changes that callers and other files must make

- `User.changeset/2` must exist and declare the duplicate check. It is assumed absent here:

  ```elixir
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :age, :role, :nickname])
    |> validate_required([:email, :age, :role])
    |> unique_constraint(:email)
  end
  ```

  The migration needs a unique index on `users.email`, and `role` is assumed to be an `Ecto.Enum` field.
- The role names `:admin`, `:editor` and `:viewer` are placeholders. Replace them with the application's real roles.
- `Accounts.TaskSupervisor` must be started in the supervision tree, for example `{Task.Supervisor, name: Accounts.TaskSupervisor}`.
- Public API changes: `:silent` is removed, and `:return_id` is replaced by `import_user_id/2`, which returns `{:ok, id}` instead of a bare integer. Callers that passed `silent:` or `return_id:` must be updated.
- `User` is assumed to have `nickname` set on import and a `@type t`.
