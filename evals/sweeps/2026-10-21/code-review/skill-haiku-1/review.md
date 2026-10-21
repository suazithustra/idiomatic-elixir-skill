# Review: `Accounts.UserImporter`

The module has a rescue that hides errors, a clamp on age that never runs, and a welcome email that never sends. Each finding below names the rule from the idiomatic-elixir skill, quotes the line, and gives the fix. The improved module follows.

## Findings

1. **Atoms from input (line 8).** Rule: convert external strings to atoms with explicit clauses. `String.to_atom(params["role"])` creates an atom for any string the file contains. Atoms are never freed, so a large or hostile file can exhaust the atom table and crash the node. A missing role also raises outside the `try`. Fix: a `parse_role/1` function with one clause per accepted role. The role names in the fix are placeholders; replace them with the project's real roles.

2. **Catch-all rescue (lines 10 and 38–40).** Rule: rescue only specific exceptions, never `rescue _ ->` around a whole function. Any bug in the body, including a database failure from `Repo.insert/1`, becomes `{:error, :invalid}`, so the cause is lost. Fix: remove the `try`.

3. **Raising parse (line 13).** Rule: call the non-raising version instead of wrapping a raising call in `try`. `String.to_integer/1` raises on bad input. Fix: `Integer.parse/1` with explicit clauses.

4. **Clamp that never runs (lines 15–17).** Rule: assign the result of `if`; rebinding inside a block does not escape it. `age = 120` is local to the `if`, so the outer `age` keeps its value and ages above 120 are stored unchanged. The compiler also warns about it. Fix: `min(age, @max_age)`.

5. **Missing email raises inside the `try` (line 12).** Rule: match every expected shape; pattern match required keys. `params["email"] |> String.downcase()` raises for a missing key, and the catch-all rescue then hides the error. Fix: match `"email"` in the function head with an `is_binary/1` guard. The single-step pipe is also removed.

6. **`&&` on booleans (line 21).** Rule: use `and` when the operands are booleans. `is_binary(email)` also runs after line 12 has already crashed on a non-string, so it can never fail. Fix: the guard in finding 5 replaces it.

7. **Overlapping booleans (line 26).** Rule: use one atom-valued option instead of overlapping booleans. `notify: true, silent: true` has no clear meaning. Fix: one `:delivery` option, with values `:welcome_email` and `:none`, checked with `Keyword.validate!/2`. Callers that pass `notify:`, `silent:`, or `return_id:` must change; this is a breaking change.

8. **Two return shapes (line 30).** Rule: give each function one return shape. With `return_id: true` the function returns a bare integer, and otherwise a tuple. Fix: `import_user_id/2` returns `{:ok, id}`, and `import_user/2` always returns a tuple.

9. **Catch-all after `{:ok, user}` (lines 32–33).** Rule: match every expected shape. `Repo.insert/1` returns only `{:ok, struct}` or `{:error, changeset}`, and `_ ->` throws the changeset away. Fix: match `{:error, changeset}` and keep it in the reason.

10. **Unsupervised process (line 45).** Rule: supervise every long-lived process. A bare `spawn/1` has no supervisor, so a crash in the mail send is lost and nothing restarts it. Fix: `Task.Supervisor.start_child/2`. This needs `Accounts.TaskSupervisor` in the application's supervision tree.

11. **Struct read with `Access` (line 49).** Rule: structs do not implement `Access`; `user[:name]` raises `UndefinedFunctionError`. The call runs inside the spawned process, so the welcome email never sends and nothing reports the failure. Fix: `user.nickname`, which the importer always sets. This assumes `User` has no `name` field in this code; check the schema.

12. **Anonymous function in a pipe (lines 50–51).** Rule: do not pipe into an anonymous function call. Fix: string interpolation.

13. **Comments that restate the code (lines 2, 4, 7, 44) and missing docs.** Rule: comments explain why; documentation goes in `@moduledoc` and `@doc`. Lines 2, 4, 7, and 44 repeat what the code says. The comment on line 11 explains a reason and stays. The public function has no `@doc`. Fix: remove the restating comments, add `@moduledoc` and `@doc`.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports one user and returns `{:ok, user}`.

  Returns `{:error, :invalid}` when the params fail validation and
  `{:error, {:insert_failed, changeset}}` when the database rejects the row.

  ## Options

    * `:delivery` - `:welcome_email` sends a welcome email after the insert.
      `:none` sends nothing. Defaults to `:none`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, delivery: :none)

    with {:ok, new_user} <- parse_params(params),
         {:ok, user} <- insert_user(new_user) do
      if opts[:delivery] == :welcome_email, do: send_welcome(user)
      {:ok, user}
    end
  end

  @doc """
  Like `import_user/2`, but returns `{:ok, id}` with only the new user's ID.
  """
  def import_user_id(params, opts \\ []) do
    with {:ok, user} <- import_user(params, opts), do: {:ok, user.id}
  end

  defp parse_params(%{"email" => email, "age" => age, "role" => role} = params)
       when is_binary(email) and is_binary(age) and is_binary(role) do
    with {:ok, role} <- parse_role(role),
         {:ok, age} <- parse_age(age) do
      # The provider lowercases addresses before its uniqueness check, so match it here
      email = String.downcase(email)
      {:ok, %User{email: email, age: age, role: role, nickname: params["nickname"] || email}}
    end
  end

  defp parse_params(_params), do: {:error, :invalid}

  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("editor"), do: {:ok, :editor}
  defp parse_role("viewer"), do: {:ok, :viewer}
  defp parse_role(_role), do: {:error, :invalid}

  defp parse_age(text) do
    case Integer.parse(text) do
      {age, ""} when age >= @min_age -> {:ok, min(age, @max_age)}
      {_age, _rest} -> {:error, :invalid}
      :error -> {:error, :invalid}
    end
  end

  defp insert_user(%User{} = user) do
    case Repo.insert(user) do
      {:ok, user} -> {:ok, user}
      {:error, changeset} -> {:error, {:insert_failed, changeset}}
    end
  end

  defp send_welcome(user) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

## Behavior changes to check

- Unknown roles now return `{:error, :invalid}`. The old code accepted any role string.
- Ages above 120 are now stored as 120. The old code intended this but never did it (finding 4).
- Welcome emails now send. The old code crashed in the spawned process (finding 11).
- `Accounts.TaskSupervisor` must exist in the supervision tree.
- The `:return_id`, `:notify`, and `:silent` options are removed.
