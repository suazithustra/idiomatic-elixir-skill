# Review of `Accounts.UserImporter`

## Findings

1. **Bug: `age = 120` inside `if` has no effect** (rule: assign the result of `if`; rebinding inside a block does not escape it). `if age > 120 do age = 120 end` leaves `age` unchanged, so the cap is never applied. Fix: `min(age, @max_age)`.

2. **Bug: `String.to_atom(params["role"])`** (rule: convert external strings to atoms with explicit clauses). Input can exhaust the atom table, and a missing role raises `ArgumentError` outside the `try`. Fix: `parse_role/1` with one clause per accepted role and an `{:error, {:unknown_role, other}}` fallback. I assumed the roles `:admin`, `:editor`, `:member`; change them to the real set.

3. **`try ... rescue _ ->` around the whole function** (rule: return tuples for expected failures; never `rescue _`). It hides real bugs and reports them as `:invalid`. Fix: use `Integer.parse/1` and function-head matching, chained with `with`. Each step returns `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}`, so callers learn which field failed.

4. **`String.downcase` runs before the `is_binary(email)` check**, so a missing email raises, and the check afterwards is dead code. Fix: validate in `fetch_email/1`, then downcase.

5. **`opts[:return_id]` changes the return shape** (rule: one return shape per function). The function returns either an id or `{:ok, user}`. Fix: removed. It always returns `{:ok, user}`. Callers that want the id can use `user.id`.

6. **Overlapping booleans `notify` and `!silent`**, combined with `&&` and `!` (rules: one atom/boolean option instead of overlapping booleans; `and`/`not` for booleans). `notify: true, silent: true` is contradictory. Fix: a single `:notify` option, checked with `Keyword.validate!/2` and documented.

7. **`_ -> {:error, :insert_failed}` after `{:ok, user}`** (rule: match every expected shape). It discards the changeset errors. Fix: `Repo.insert/1` already returns `{:error, changeset}`, so `with` passes it through.

8. **`spawn/1` with no supervisor** (processes reference: supervise long-lived processes; use `Task.Supervisor.start_child/2`). A crash in `Mailer.deliver` is unsupervised and untracked. Fix: `Task.Supervisor.start_child(Accounts.TaskSupervisor, ...)`. This needs `{Task.Supervisor, name: Accounts.TaskSupervisor}` in the application's supervision tree.

9. **`user[:name]` on a struct** (rule: `map.key` for required keys; structs do not implement `Access`). It raises `UndefinedFunctionError`. Also, the struct built here has no `:name` field. Fix: use `user.nickname`. This is an assumption: if `User` has a `name` field, use that instead.

10. **`|> (fn ... end).()`** (rule: no pipe into an anonymous function). Fix: a single interpolated string.

11. **`age > 120` / `age >= 18` and other magic numbers** (rule: name magic numbers). Fix: `@min_age 18`, `@max_age 120`.

12. **Comments that restate the code** (`# Get the role from params`, `# send the email`, and similar) and function docs written as comments (rule: comments explain why; use `@moduledoc`/`@doc`). Fix: deleted them, added `@moduledoc` and `@doc` with `## Options` and examples. Kept the comment about the provider lowercasing addresses, since it gives a reason.

13. **One long function with nested `if`/`case`** (rule: short functions at one level of detail). Fix: `import_user/2` is now a short `with` chain over small private functions.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from external CSV/JSON params.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from string-keyed `params`.

  Requires `"email"`, `"age"`, and `"role"`. `"nickname"` is optional and
  defaults to the email. Ages above #{@max_age} are capped at #{@max_age}.

  Returns `{:ok, user}`, `{:error, {:missing_field, key}}`,
  `{:error, {:invalid_field, key}}`, `{:error, {:unknown_role, role}}`,
  `{:error, :underage}`, or `{:error, changeset}` when the insert fails.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, email} <- fetch_email(params),
         {:ok, age} <- fetch_age(params),
         {:ok, role} <- fetch_role(params),
         :ok <- check_adult(age),
         user = %User{email: email, age: age, role: role, nickname: params["nickname"] || email},
         {:ok, user} <- Repo.insert(user) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  # The provider lowercases addresses before its uniqueness check, so match it here
  defp fetch_email(%{"email" => email}) when is_binary(email), do: {:ok, String.downcase(email)}
  defp fetch_email(%{"email" => _}), do: {:error, {:invalid_field, "email"}}
  defp fetch_email(_params), do: {:error, {:missing_field, "email"}}

  defp fetch_age(%{"age" => age}) when is_integer(age), do: {:ok, min(age, @max_age)}

  defp fetch_age(%{"age" => age}) when is_binary(age) do
    case Integer.parse(age) do
      {age, ""} -> {:ok, min(age, @max_age)}
      _ -> {:error, {:invalid_field, "age"}}
    end
  end

  defp fetch_age(%{"age" => _}), do: {:error, {:invalid_field, "age"}}
  defp fetch_age(_params), do: {:error, {:missing_field, "age"}}

  defp fetch_role(%{"role" => role}), do: parse_role(role)
  defp fetch_role(_params), do: {:error, {:missing_field, "role"}}

  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("editor"), do: {:ok, :editor}
  defp parse_role("member"), do: {:ok, :member}
  defp parse_role(other), do: {:error, {:unknown_role, other}}

  defp check_adult(age) when age >= @min_age, do: :ok
  defp check_adult(_age), do: {:error, :underage}

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

## Notes

- The error reasons changed: the old `:invalid` and `:insert_failed` are replaced by the tagged tuples above. Callers that match on the old atoms need updating.
- I did not compile this because `Repo`, `User`, and `Mailer` are not available in the file.
