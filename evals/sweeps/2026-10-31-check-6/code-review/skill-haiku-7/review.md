# Review: `Accounts.UserImporter`

## Findings

1. The age cap never takes effect. Lines 15–17 assign `age = 120` inside an `if`, and the new value does not leave the block, so an age above 120 is stored unchanged and the compiler warns about it. Rule: "Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it" (SKILL.md). Fix: `min(age, @max_age)` where the age is parsed.

2. A `try` with `rescue _ ->` around the whole function hides every failure, including bugs in the code itself. The `String.to_integer/1` call inside it raises on bad input and is used to pick the error. Rule: "Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs" (SKILL.md). Fix: `Integer.parse/1` with an explicit `{age, ""}` match, and no `try`.

3. `String.to_atom(params["role"])` on line 8 creates an atom from input, and the atom table is never cleaned up, so a caller can exhaust it. Line 8 also sits outside the `try`, so a missing role crashes the import. Rule: "Convert external strings to atoms with explicit clauses" (SKILL.md). Fix: one clause per accepted role, with a catch-all that returns `{:error, {:invalid_field, "role"}}`.

4. Line 24 checks `Repo.get_by(User, email: email) == nil` and then inserts. Two imports of the same address can both pass the check, and the second insert then fails or creates a duplicate. Rule: "Declare database constraints in the changeset (`unique_constraint/3`...)" in the Ecto section of `references/ecto-phoenix.md`. Fix: `unique_constraint(:email)` in the changeset, plus a unique index on `email` in the database, and no lookup before the insert.

5. Line 22 builds `%User{...}` and line 25 passes it straight to `Repo.insert/1`, so no validation runs. The checks on lines 21 and 39 (`is_binary(email) && age >= 18`) are written by hand, and the `is_binary` part is dead, because `String.downcase/1` on line 12 already raises for a non-string. Rule: "Validate input with changesets" (`references/ecto-phoenix.md`). Fix: `User.changeset/2` with `validate_required/2` and `validate_number(:age, greater_than_or_equal_to: 18)`, then `Repo.insert/1` on the changeset. The nested `if` blocks go away with it.

6. Lines 25–35 end the `case Repo.insert(user)` with `_ -> {:error, :insert_failed}`, which turns any later return value, and the changeset errors that matter to callers, into one reason. Rule: "Match every expected shape and let unexpected ones crash" (SKILL.md). Fix: the `with` in the new `import_user/2` passes `{:error, changeset}` through unchanged, so no catch-all is needed.

7. Line 31 returns a bare `user.id` when `:return_id` is set and `{:ok, user}` otherwise, so one function has two return shapes. Rule: "Give each function one return shape" (SKILL.md). Fix: `import_user/2` always returns `{:ok, user}`, and a separate `import_user_id/2` returns `{:ok, id}`.

8. Options `:notify` and `:silent` overlap: `silent` only matters when `notify` is set, and a caller can pass both. Rule: "Use one atom-valued field or option instead of overlapping booleans" (SKILL.md). Fix: drop `:silent`, keep `notify: true`. Callers that pass `silent: true` must stop passing it.

9. Line 27 uses `&&` and `!` on booleans. Rule: "Use `and`, `or`, `not` when the operands are booleans" (SKILL.md). Fix: the rewritten function uses `if opts[:notify]`, so no boolean operator is left.

10. Line 49 starts the welcome email with a bare `spawn/1`, outside any supervisor, so a crash is lost and the process does not show in tools. Rule: "Supervise every long-lived process" (`references/processes.md`). Fix: `Task.Supervisor.start_child/2` under a named task supervisor. The closure also captures `user` when only the email text is needed, so the text is built first.

11. Line 53 reads `user[:name]`. `user` is a `%User{}` struct, and structs do not implement `Access`, so this raises `UndefinedFunctionError`. Rule: "Read required keys with `map.key` or a pattern; keep `map[:key]` for optional keys" (SKILL.md), which says "Structs do not implement `Access`". Fix: read `user.nickname`, the field this import always sets. If the greeting should use another field, change the field name.

12. Line 55 pipes into an anonymous function, `|> (fn text -> ... end).()`. Rule: "Write pipelines that start with a value and read top to bottom" (SKILL.md), which says "Do not pipe into an anonymous function call". Fix: one string interpolation.

13. Line 12 pipes one step, `params["email"] |> String.downcase()`. Rule: "Write pipelines that start with a value and read top to bottom" (SKILL.md), which says "Do not pipe a single step". Fix: `String.downcase(raw_email)`.

14. Comments on lines 2, 5, 7, and 48 restate the code: "This module imports...", "Import a single user...", "Get the role from params", "send the email". Rule: "Comments explain why; documentation goes in `@moduledoc` and `@doc`" (SKILL.md). Fix: delete them, and keep the line 11 comment, which gives the reason for the lowercasing. The module description becomes `@moduledoc`, and the public function gets a `@doc` with its options.

## Improved version

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports single users from external comma-separated (CSV) or JSON sources.
  """

  alias Accounts.{Repo, User}

  @max_age 120

  @doc """
  Imports one user from string-keyed `params`.

  Returns `{:ok, user}`. Returns `{:error, {:missing_field, key}}` or
  `{:error, {:invalid_field, key}}` when a field cannot be read, and
  `{:error, changeset}` when validation or the database rejects the row.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    with {:ok, attrs} <- user_attrs(params),
         {:ok, user} <- insert_user(attrs) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  @doc """
  Like `import_user/2`, but returns `{:ok, id}`.
  """
  def import_user_id(params, opts \\ []) do
    with {:ok, user} <- import_user(params, opts), do: {:ok, user.id}
  end

  defp user_attrs(params) do
    with {:ok, raw_email} <- string_field(params, "email"),
         {:ok, age} <- parse_age(params["age"]),
         {:ok, role} <- parse_role(params["role"]) do
      # The provider lowercases addresses before its uniqueness check, so match it here
      email = String.downcase(raw_email)
      attrs = %{email: email, age: age, role: role, nickname: params["nickname"] || email}

      {:ok, attrs}
    end
  end

  defp insert_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp string_field(params, key) do
    case params[key] do
      nil -> {:error, {:missing_field, key}}
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, {:invalid_field, key}}
    end
  end

  defp parse_age(nil), do: {:error, {:missing_field, "age"}}

  defp parse_age(text) when is_binary(text) do
    case Integer.parse(text) do
      {age, ""} -> {:ok, min(age, @max_age)}
      _ -> {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(_other), do: {:error, {:invalid_field, "age"}}

  # The accepted roles are placeholders; replace them with the application's roles
  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("editor"), do: {:ok, :editor}
  defp parse_role("viewer"), do: {:ok, :viewer}
  defp parse_role(_other), do: {:error, {:invalid_field, "role"}}

  defp send_welcome(user) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

The changeset this code expects in `Accounts.User`:

```elixir
def changeset(user, attrs) do
  user
  |> cast(attrs, [:email, :age, :role, :nickname])
  |> validate_required([:email, :age, :role])
  |> validate_number(:age, greater_than_or_equal_to: 18)
  |> unique_constraint(:email)
end
```

## Assumptions

- `Accounts.User` has a `changeset/2` as above, its `role` is an `Ecto.Enum` field, and `email` has a unique index in the database. Without the index, the `unique_constraint/3` call catches nothing.
- `Accounts.TaskSupervisor` is started in the application's supervision tree.
- The roles `:admin`, `:editor`, and `:viewer` are placeholders.
- The welcome greeting uses `nickname`, the field this import sets. The original code read `name`, which raises on a struct.
- Behavior changes: the age cap now applies (finding 1). Duplicate emails and under-18 ages return `{:error, changeset}` instead of `{:error, :invalid}`. `:return_id` and `:silent` are removed, and `import_user_id/2` takes over the first.
- I could not run `mix format` or the compiler here, because the shell command to check for Elixir was denied. The code is checked by reading only.
