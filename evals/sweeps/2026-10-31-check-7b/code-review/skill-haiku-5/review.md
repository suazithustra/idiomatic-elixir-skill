# Review: `Accounts.UserImporter`

Source: `code-review-input.ex`. Rules are from the idiomatic-elixir skill. The Ecto and processes reference files were read because the code calls `Repo` and `spawn`.

## Findings

1. The age cap never runs. `if age > 120 do age = 120 end` (lines 15-17) sets `age` inside the `if`, and the new value is lost when the block ends, so a user aged 150 is saved as 150. Rule: assign the result of `if`, `case`, and `Enum` calls. Fix: `age: min(age, @max_age)`.

2. The welcome email is never sent. `user[:name] || "there"` (line 53) raises because structs (typed maps) do not support bracket access. The crash happens inside the spawned process, so nothing reports it. Rule: read required keys with `map.key`; structs do not implement `Access`. Fix: use `user.nickname`, which the importer always sets, so the `"there"` fallback is not needed.

3. `String.to_atom/1` runs on input (line 8). Anyone who can send a role can add atoms to the VM (virtual machine) atom table, which has a fixed limit, and a missing role raises outside the `try`. Rule: convert external strings to atoms with explicit clauses. Fix: `parse_role/1` with one clause per allowed role. `:admin` and `:member` are placeholders; use the app's real roles.

4. `try ... rescue _ -> {:error, :invalid}` wraps the whole function (lines 10, 42-44). A bug anywhere in the function, including a typo, is reported as invalid input. Rule: return tuples for expected failures and raise only for bugs; never `rescue _` around a whole function. Fix: remove the `try` and use non-raising calls.

5. `String.to_integer/1` raises on a non-number (line 13). Rule: call the non-raising version. Fix: `Integer.parse/1`, returning `{:error, {:invalid_field, "age"}}` on failure.

6. Lookup before insert (lines 24-25). `Repo.get_by(User, email: email) == nil` followed by `Repo.insert(user)` lets two imports of the same address both pass the check. Rule: validate input with changesets and declare uniqueness with `unique_constraint/3`. Fix: build the user with `User.changeset/2`, which calls `unique_constraint(:email)`, and insert the changeset with `Repo.insert/1`. A duplicate then comes back as `{:error, changeset}`.

7. Catch-all clause (line 33). `_ -> {:error, :insert_failed}` turns every other return shape into the same error and drops the reason. Rule: match every expected shape. Fix: `{:error, failed} -> {:error, {:insert_failed, failed}}`.

8. One error for every failure (lines 37, 40, 43). A missing email, a bad age, an underage user, and a duplicate all return `:invalid`, so callers cannot tell them apart. Rule: different failures need different reasons. Fix: `{:missing_field, key}`, `{:invalid_field, key}`, `:underage`, and `{:insert_failed, changeset}`.

9. An option changes the return shape (line 31). `if opts[:return_id], do: user.id, else: {:ok, user}` returns a bare ID in one mode and a tuple in the other. Rule: give each function one return shape. Fix: `import_user/2` always returns `{:ok, user}`, and a new `import_user_id/2` returns `{:ok, id}`.

10. Two options overlap (line 27). `opts[:notify] && !opts[:silent]` means `silent` only cancels `notify`, so the two options describe one setting. Rule: use one option instead of overlapping booleans. Fix: remove `silent`. The default `notify: false` covers it, and `Keyword.validate!/2` now rejects `silent:`, so old callers fail loudly.

11. Options are neither validated nor documented (line 6, `opts \\ []`). Rule: check options with `Keyword.validate!/2` and document them under `## Options` in `@doc`. Fix: `Keyword.validate!(opts, notify: false)` and an `## Options` section in `@doc`.

12. Boolean operators on booleans (line 21, `is_binary(email) && age >= 18`). Rule: use `and`, `or`, and `not` when the operands are booleans. Fix: the age check moves into `check_age/1`, and the email check moves into `string_field/2`, so no boolean operator is left.

13. Nested `if` and `case` four levels deep (lines 15-44). Rule: chain fallible steps with `with`, and move each step into a small private function. Fix: a `with` chain in `build_attrs/1` and `import_user/2`.

14. Bare `spawn/1` (line 49). A process started with `spawn` has no supervisor, so a crash is not restarted and is not visible to supervision tools. The closure also captures the whole `user`. Rule: supervise every long-lived process, and pass a closure only the data it needs. Fix: `Task.Supervisor.start_child/2` under `Accounts.TaskSupervisor`, with the closure capturing only the built message.

15. Pipe into an anonymous function (line 55). `greeting |> (fn text -> ... end).()`. Rule: do not pipe into an anonymous function call. Fix: one string literal in `welcome_email/1`.

16. Single-step pipe (line 12). `params["email"] |> String.downcase()`. Rule: do not pipe a single step. Fix: `String.downcase(email)`.

17. Magic numbers (lines 15 and 21, `120` and `18`). Rule: name magic numbers with module attributes. Fix: `@max_age 120` and `@min_age 18`.

18. Comments in the wrong place. Lines 2 and 5 describe the module and a function, which belongs in `@moduledoc` and `@doc`. Lines 7 and 48 restate the code. Rule: comments explain why; documentation goes in `@moduledoc` and `@doc`. Fix: add `@moduledoc` and `@doc`, delete the restating comments, and keep the comment on line 11, which gives a reason.

## Behavior changes

- Ages above 120 are saved as 120.
- The welcome email is sent with the nickname in the greeting.
- `import_user/2` returns `{:ok, user}` or `{:error, reason}` only. Use `import_user_id/2` for the ID.
- Error reasons changed as listed in finding 8. Callers that matched `:invalid` need updating.
- `silent:` is no longer accepted. A caller that passed `notify: true, silent: true` should pass `notify: false`.

## Assumptions

- `User.changeset/2` exists, casts `email`, `age`, `role`, and `nickname`, and calls `unique_constraint(:email)`.
- `User` has a `nickname` field. The original code sets it.
- `Accounts.TaskSupervisor` is started in the application's supervision tree.
- `:admin` and `:member` are placeholder roles.
- `Mailer` is unchanged from the original, and the original code does not alias it.

## Checks

The improved module compiles and passes `mix format --check-formatted` when `Accounts.User`, `Accounts.Repo`, and `Mailer` are stubbed. It has not been run against the real project.

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
  Imports a single user from the given params.

  Returns `{:ok, user}` or `{:error, reason}`. Reasons are
  `{:missing_field, key}`, `{:invalid_field, key}`, `:underage`, and
  `{:insert_failed, changeset}`.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, attrs} <- build_attrs(params),
         {:ok, user} <- insert_user(attrs) do
      if opts[:notify], do: send_welcome(user)

      {:ok, user}
    end
  end

  @doc """
  Imports a single user and returns its ID.

  Takes the same arguments as `import_user/2`.
  """
  def import_user_id(params, opts \\ []) do
    with {:ok, user} <- import_user(params, opts) do
      {:ok, user.id}
    end
  end

  defp build_attrs(params) do
    with {:ok, email} <- string_field(params, "email"),
         {:ok, age_text} <- string_field(params, "age"),
         {:ok, age} <- parse_age(age_text),
         {:ok, role_text} <- string_field(params, "role"),
         {:ok, role} <- parse_role(role_text),
         :ok <- check_age(age) do
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
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp parse_age(text) do
    case Integer.parse(text) do
      {age, ""} -> {:ok, age}
      _ -> {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("member"), do: {:ok, :member}
  defp parse_role(_role), do: {:error, {:invalid_field, "role"}}

  defp check_age(age) when age >= @min_age, do: :ok
  defp check_age(_age), do: {:error, :underage}

  defp insert_user(attrs) do
    changeset = User.changeset(%User{}, attrs)

    case Repo.insert(changeset) do
      {:ok, user} -> {:ok, user}
      {:error, failed} -> {:error, {:insert_failed, failed}}
    end
  end

  defp send_welcome(user) do
    message = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(message) end)
  end

  defp welcome_email(user), do: "Hi #{user.nickname}, welcome! Enjoy your account."
end
```
