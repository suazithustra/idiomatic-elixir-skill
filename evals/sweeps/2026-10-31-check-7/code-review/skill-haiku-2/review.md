# Review: `Accounts.UserImporter`

## Findings

1. **Input creates atoms.** The line `role = String.to_atom(params["role"])` turns external text into an atom. Atoms are never freed, so a caller can exhaust the atom table and crash the node. A missing `role` also raises here, outside the `try`. Rule: "Convert external strings to atoms with explicit clauses". Fix: match each accepted role with its own `parse_role/1` clause.

2. **The age cap never applies.** The line `age = 120` inside `if age > 120 do` rebinds `age` only inside the `if` block, so the outer `age` keeps its value and an age of 150 is saved as 150. Rule: "Assign the result of `if`, `case`, and `Enum` calls". Fix: `age: min(age, @max_age)`.

3. **A catch-all `rescue` hides bugs.** The `try` wraps the whole function, and `rescue _ -> {:error, :invalid}` turns every exception, including programming errors, into the same reply. `String.to_integer(params["age"])` raises on `"abc"` where `Integer.parse/1` returns `:error`. Rule: "Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs". Fix: use `Integer.parse/1`, and remove the `try`.

4. **Uniqueness is checked by hand, which races.** `Repo.get_by(User, email: email) == nil` followed by `Repo.insert(user)` lets two imports of the same email both pass the check. The insert also takes a bare `%User{}` struct with no changeset, so nothing is validated. Rule: "Declare database constraints in the changeset" (ecto-phoenix reference, "Validate input with changesets"). Fix: insert through `User.changeset/2`, which declares `unique_constraint(:email)`, and rely on a unique index in the database.

5. **The insert error is thrown away.** `_ -> {:error, :insert_failed}` drops the reason and matches every non-`:ok` value. Rule: "Match every expected shape and let unexpected ones crash". Fix: let `with` pass `{:error, changeset}` through unchanged.

6. **An option changes the return type.** `if opts[:return_id], do: user.id, else: {:ok, user}` returns an integer in one mode and a tuple in the other. Rule: "Give each function one return shape". Fix: always return `{:ok, user}`; callers read `user.id`.

7. **Two overlapping booleans.** `opts[:notify] && !opts[:silent]` has a case where `notify: true, silent: true` means nothing sensible. Rule: "Use one atom-valued field or option instead of overlapping booleans". Fix: keep one `notify` option. `silent` is removed, because `notify: false` already means silent.

8. **Dot-free access on a struct.** `user[:name]` raises `UndefinedFunctionError`, because structs do not implement `Access`. The welcome email runs in a spawned process, so the crash is silent. Rule: "Read required keys with `map.key` or a pattern; keep `map[:key]` for optional keys". Fix: read `user.nickname`, the field the import sets. If the greeting should use a different field, change it there.

9. **Pipe into an anonymous function, and a one-step pipe.** `greeting |> (fn text -> ... end).()` is not allowed; the one-step `params["email"] |> String.downcase()` is also a pipe. Rule: "Write pipelines that start with a value and read top to bottom". Fix: build the greeting with interpolation and call `String.downcase(email)` directly.

10. **`&&` on booleans.** `is_binary(email) && age >= 18` should use `and`. The check itself is gone in the fix, because `email` is now validated by `string_field/2` and the age floor by `parse_age/1`.

11. **Bare `spawn`.** `spawn(fn -> Mailer.deliver(...) end)` runs outside any supervisor, so a crash is lost and nothing shows it. Rule: "Supervise every long-lived process" (processes reference). Fix: `Task.Supervisor.start_child/2` under a named supervisor.

12. **Errors are not specific.** Missing fields, bad numbers, under-age users, and database failures all return `:invalid`. Rule: "Match every expected shape and let unexpected ones crash" (the rule also says different failures need different reasons). Fix: return `{:missing_field, key}`, `{:invalid_field, key}`, or `{:under_minimum_age, 18}`.

13. **Comments restate the code.** `# Get the role from params`, `# send the email`, and `# Import a single user` describe what the next line does. The module comment belongs in `@moduledoc`, and the function comment in `@doc`. Rule: "Comments explain why; documentation goes in `@moduledoc` and `@doc`". The provider comment about lowercasing stays, because it explains a reason.

14. **Too much nesting in one function.** The import function has five levels of `try`, `if`, `if`, `if`, and `case`. Rule: "Keep functions short and at one level of detail". Fix: validation, insert, and notification become private steps chained with `with`.

Assumptions in the fix. Each one is a fact about the rest of the project that this file does not show:
- `User.changeset/2` exists and calls `unique_constraint(:email)`, and the database has a unique index on `email`.
- `Accounts.TaskSupervisor` is started in the application's supervision tree.
- The roles `:admin`, `:editor`, and `:member` are placeholders. Replace them with the app's real roles.
- The `User` schema has a `nickname` field, which the original code already sets.
- Callers that pass `silent:` or `return_id:` now get an `ArgumentError` from `Keyword.validate!/2`. Update those callers.
- A database failure now returns `{:error, %Ecto.Changeset{}}` instead of `{:error, :insert_failed}`.

## Improved version

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports one user from string-keyed params.

  Returns `{:ok, user}`. On failure, returns `{:error, reason}`, where `reason`
  names the field that failed, such as `{:missing_field, "email"}`, or is an
  `Ecto.Changeset` when the database rejects the row.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, attrs} <- parse_attrs(params),
         {:ok, user} <- insert_user(attrs) do
      if opts[:notify], do: send_welcome(user)

      {:ok, user}
    end
  end

  defp parse_attrs(params) do
    with {:ok, email} <- string_field(params, "email"),
         {:ok, age} <- parse_age(params["age"]),
         {:ok, role} <- parse_role(params["role"]) do
      # The provider lowercases addresses before its uniqueness check, so match it here
      email = String.downcase(email)

      attrs = %{
        email: email,
        age: min(age, @max_age),
        role: role,
        nickname: params["nickname"] || email
      }

      {:ok, attrs}
    end
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
      {age, ""} when age >= @min_age -> {:ok, age}
      {_age, ""} -> {:error, {:under_minimum_age, @min_age}}
      _ -> {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(_other), do: {:error, {:invalid_field, "age"}}

  defp parse_role(nil), do: {:error, {:missing_field, "role"}}
  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("editor"), do: {:ok, :editor}
  defp parse_role("member"), do: {:ok, :member}
  defp parse_role(_other), do: {:error, {:invalid_field, "role"}}

  defp insert_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp send_welcome(user) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user) do
    name = user.nickname || "there"
    "Hi #{name}, welcome! Enjoy your account."
  end
end
```
