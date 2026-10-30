# Review: `Accounts.UserImporter`

## Findings

1. **Welcome email never sends (struct access).** Rule: read struct fields with `user.name` or a pattern, never `user[:name]` (Access, the `[]` lookup). Line 53, `name = user[:name] || "there"`, raises `UndefinedFunctionError` because `User` is a struct. The raise happens inside the spawned process, so nothing reports it. Fix: build the greeting from `user.nickname`, which the import always sets.

2. **Age cap does nothing.** Rule: a variable rebound inside `if` does not escape the block. Lines 15-17, `if age > 120 do age = 120 end`, leave `age` unchanged, so ages above 120 are stored. Fix: `min(age, @max_age)`.

3. **Whole function wrapped in `rescue _ ->`.** Rule: rescue only a specific exception around third-party code, never `rescue _ ->` around a whole function. Lines 10 and 42-43 turn database failures and programming bugs into `{:error, :invalid}`. Fix: remove the `try`; expected failures return tuples from the steps that can fail.

4. **`String.to_atom/1` on input.** Rule: convert external strings to atoms with explicit clauses. Line 8, `String.to_atom(params["role"])`, lets input create atoms, and a missing role crashes outside the `try`. Fix: `parse_role/1` maps the accepted names with `Map.fetch/2`, which returns `:error` for `nil`.

5. **`String.to_integer/1` raises on bad input.** Rule: use the non-raising version and return a tuple for an expected failure. Line 13 raises on `"abc"`. Fix: `Integer.parse/1`, with a clause for each result.

6. **Lookup before insert, and no validation.** Rule: validate with a changeset and declare `unique_constraint/3`; do not check for duplicates by hand. Lines 22-25 build `%User{}` directly, so nothing is validated, and the `Repo.get_by/2` check before `Repo.insert/1` races with a concurrent insert. Fix: `%User{role: role} |> User.changeset(attrs) |> Repo.insert()`.

7. **Catch-all error clause.** Rule: match the error shape explicitly. Line 33, `_ -> {:error, :insert_failed}`, hides the changeset that says why the insert failed. Fix: the changeset is returned as the error.

8. **Return shape depends on an option.** Rule: options must not change what a function returns. Line 31, `if opts[:return_id], do: user.id, else: {:ok, user}`, returns two different shapes. Fix: `import_user_id/2` is a separate function that returns `{:ok, id}`.

9. **Options are unchecked and overlap.** Rule: check options with `Keyword.validate!/2`, and use one atom instead of overlapping booleans. Line 27, `opts[:notify] && !opts[:silent]`, accepts any key and any value. Fix: `Keyword.validate!(opts, notify: :none)` and `notify: :welcome_email`. This removes the `silent:` option; callers that passed `silent: true` must drop it.

10. **Unsupervised `spawn`.** Rule: start long-lived or side-effect work under a supervisor. Line 49, `spawn(fn -> ... end)`, has no supervision, so a crash is lost and the process is not visible. Fix: `Task.Supervisor.start_child/2` under `Accounts.TaskSupervisor`, which must be in the application's supervision tree.

11. **Single-step pipe and pipe into an anonymous function.** Rule: do not pipe a single step; do not pipe into `(fn ... end).()`. Line 12, `params["email"] |> String.downcase()`, and line 55, `greeting |> (fn text -> ... end).()`. Fix: call the function directly and interpolate the string.

12. **`&&` on booleans.** Rule: use `and` when the operands are booleans. Line 21, `is_binary(email) && age >= 18`. Fix: the checks moved into `parse_email/1` and `check_adult/1`, so no `&&` remains.

13. **Comments restate the code; no module or function docs.** Rule: comments explain why; documentation goes in `@moduledoc` and `@doc`. Lines 2, 5, 7 and 48 restate the code, and the public function has no `@doc`. Fix: `@moduledoc`, `@doc` on each public function, and one comment kept where a reason is not visible in the code (the email lowercasing).

14. **One function does parsing, validation, insertion and notification.** Rule: keep functions short and at one level of detail. Lines 6-45 nest four `if`/`case` levels. Fix: a `with` chain of named steps, each returning `{:ok, value}` or `{:error, reason}`.

## Assumptions in the improved code

- `User.changeset/2` exists, casts `email`, `age` and `nickname`, and calls `unique_constraint(:email)`. The code does not set `role` through the changeset.
- The accepted roles are `"admin"`, `"editor"` and `"member"`. Replace them with the project's real roles.
- `Accounts.TaskSupervisor` is started in the application's supervision tree.
- `Mailer.deliver/1` exists, as in the original.
- Callers now get `{:error, changeset}` for a duplicate email, not `{:error, :invalid}`.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from external CSV (comma-separated values) and JSON sources.
  """

  alias Accounts.{Repo, User}

  @roles %{"admin" => :admin, "editor" => :editor, "member" => :member}
  @min_age 18
  @max_age 120

  @doc """
  Imports one user from string-keyed params.

  Returns `{:ok, user}`, or `{:error, reason}`. `reason` is `{:invalid_field, name}`
  for a field that fails parsing, or an `Ecto.Changeset` when the database rejects
  the row, such as a duplicate email.

  ## Options

    * `:notify` - `:welcome_email` sends a welcome email after the insert.
      Defaults to `:none`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: :none)

    with {:ok, role, attrs} <- parse_params(params),
         {:ok, user} <- insert_user(role, attrs) do
      maybe_send_welcome(user, opts[:notify])
      {:ok, user}
    end
  end

  @doc """
  Same as `import_user/2`, but returns the new user's identifier (ID) instead of the struct.
  """
  def import_user_id(params, opts \\ []) do
    case import_user(params, opts) do
      {:ok, user} -> {:ok, user.id}
      {:error, _reason} = error -> error
    end
  end

  defp parse_params(params) do
    with {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         {:ok, role} <- parse_role(params["role"]),
         :ok <- check_adult(age) do
      attrs = %{
        email: email,
        age: min(age, @max_age),
        nickname: params["nickname"] || email
      }

      {:ok, role, attrs}
    end
  end

  # The provider lowercases addresses before its uniqueness check, so match it here
  defp parse_email(email) when is_binary(email), do: {:ok, String.downcase(email)}
  defp parse_email(_email), do: {:error, {:invalid_field, "email"}}

  defp parse_age(text) when is_binary(text) do
    case Integer.parse(text) do
      {age, ""} -> {:ok, age}
      {_age, _rest} -> {:error, {:invalid_field, "age"}}
      :error -> {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(_text), do: {:error, {:invalid_field, "age"}}

  defp parse_role(name) do
    case Map.fetch(@roles, name) do
      {:ok, role} -> {:ok, role}
      :error -> {:error, {:invalid_field, "role"}}
    end
  end

  defp check_adult(age) when age >= @min_age, do: :ok
  defp check_adult(_age), do: {:error, {:invalid_field, "age"}}

  defp insert_user(role, attrs) do
    %User{role: role}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp maybe_send_welcome(user, :welcome_email) do
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn ->
      Mailer.deliver(welcome_email(user))
    end)
  end

  defp maybe_send_welcome(_user, :none), do: :ok

  defp welcome_email(user), do: "Hi #{user.nickname}, welcome! Enjoy your account."
end
```
