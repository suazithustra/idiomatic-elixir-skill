# Review: `Accounts.UserImporter`

Rules applied: `idiomatic-elixir` SKILL.md, plus `references/ecto-phoenix.md` (triggered by `Repo`) and `references/processes.md` (triggered by `spawn`).

## Findings

1. **The age cap never takes effect (lines 15–17).** Rule: "Assign the result of `if`, `case`, and `Enum` calls." `age = 120` inside `if` only changes a local variable, so a value of 150 is stored as 150. The compiler also warns about it. Fix: `age = min(age, @max_age)`.

2. **The welcome email crashes in a hidden process (line 49).** Rule: "Structs do not implement `Access`." `user[:name]` raises `UndefinedFunctionError`. The email runs inside `spawn/1`, so the crash is silent and no mail is sent. This module never sets a `name` field (line 22 sets `email`, `age`, `role`, `nickname`), so the fix is `user.nickname`.

3. **Input becomes an atom (line 8).** Rule: "Convert external strings to atoms with explicit clauses." `String.to_atom(params["role"])` lets any caller add atoms to the VM (virtual machine) atom table, which is never freed. A missing role also raises here, outside the `try`. Fix: one `parse_role/1` clause per accepted value, plus an error clause.

4. **The catch-all `rescue` hides every error (lines 38–39).** Rule: "rescue the specific exception, never `rescue _ ->`." It turns bugs, database errors, and bad input into the same `{:error, :invalid}`. Fix: remove the `try` and return tuples from the parsing functions.

5. **Raising parse calls (lines 12–13).** Rule: "Call the non-raising version instead." `String.to_integer/1` raises on `"abc"`, and `String.downcase/1` raises on `nil`. Fix: `Integer.parse/1` and an `is_binary` guard, each returning `{:ok, value}` or `{:error, reason}`.

6. **Catch-all `case` clause (lines 32–33).** Rule: "Match every expected shape." `_ -> {:error, :insert_failed}` maps any future return value to the same error. Fix: pass the `{:error, changeset}` from `Repo.insert/1` through unchanged.

7. **Struct inserted without a changeset (lines 22–24).** Rule: "Validate input with changesets." `Repo.insert/1` on a bare `%User{}` skips all validation. A duplicate email raises a constraint error, and the `rescue` above turns it into `:invalid`. Fix: `User.changeset/2` with `unique_constraint(:email)`, which returns `{:error, changeset}` instead of raising.

8. **Params are read one key at a time and checked later (lines 12, 13, 19, 21).** Rule: "Parse external data into structs where it enters the system." Each `params["key"]` is read without checking, and validity is checked afterwards in `if`. Fix: `parse_params/1` runs one parse function per field inside a `with`, and each failure names its field, such as `{:invalid_field, "age"}`.

9. **Overlapping booleans (line 26).** Rule: "Use one atom-valued field or option instead of overlapping booleans." `notify: true, silent: true` is a meaningless combination. Fix: one option, `notify: :welcome`, and remove `silent`. Callers that pass `silent: true` must drop `notify` instead.

10. **An option changes the return shape (lines 30).** Rule: "Give each function one return shape." `return_id: true` returns an integer and the default returns a tuple. Fix: always return `{:ok, user}`; callers read `user.id`.

11. **`&&` and `!` on booleans (lines 21, 26).** Rule: "Use `and`, `or`, `not` when the operands are booleans." Fix: `and` and `not`, or remove the checks, since `parse_params/1` now validates the inputs.

12. **Pipe into an anonymous function (line 51).** Rule: "Do not pipe into an anonymous function call." `greeting |> (fn text -> ... end).()` is hard to read. Fix: a string interpolation: `"Hi #{user.nickname}, welcome! Enjoy your account."`.

13. **Single-step pipe (line 12).** Rule: "Do not pipe a single step." Fix: `String.downcase(params["email"])`, which the parse function in finding 5 replaces.

14. **Bare `spawn` (line 45).** Rule: "Supervise every long-lived process." A bare `spawn/1` has no supervisor, so failures go unlogged and the process is not visible to tools such as LiveDashboard. Fix: `Task.Supervisor.start_child/2` under `Accounts.TaskSupervisor`, which the application must start.

15. **Magic numbers (lines 15, 21).** Rule: "Name magic numbers with module attributes." `120` and `18` appear without names. Fix: `@max_age 120` and `@min_age 18`.

16. **Nested control flow (lines 15–37).** Rule: "When a `case`, `if`, or `with` appears inside another one, move the inner one into a named private function." An `if` contains a `case`, which contains another `if`, all inside a `try`. Fix: a `with` chain that calls named private functions.

17. **Comments (lines 2, 5, 7, 44).** Rule: "Comments explain why; documentation goes in `@moduledoc` and `@doc`." Line 2 describes the module and belongs in `@moduledoc`. Line 5 describes the function and belongs in `@doc`. Lines 7 and 44 restate the code and should be deleted. Line 11 stays because it gives the reason for the `downcase`.

## Behavior changes to check

- Errors are now tuples such as `{:error, {:invalid_field, "age"}}` and `{:error, changeset}`. Before, every failure returned `{:error, :invalid}` or `{:error, :insert_failed}`. Callers that match on those atoms must change.
- `silent:` and `return_id:` options are removed (findings 9 and 10).
- The role names `:admin`, `:editor`, and `:viewer` are placeholders. Replace them with the roles the project really uses. Before, any string became a role.
- The code assumes `User.changeset/2` exists and calls `unique_constraint(:email)`, and that `Accounts.TaskSupervisor` is in the supervision tree.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV (comma-separated values) or JSON (JavaScript Object Notation) source.
  """

  alias Accounts.{Repo, User}

  @max_age 120
  @min_age 18

  @doc """
  Imports a single user from string-keyed params.

  Ages above 120 are capped at 120. Returns `{:ok, user}` or `{:error, reason}`.

  ## Options

    * `:notify` - `:welcome` sends a welcome email after the insert. Defaults to `:none`.
  """
  def import_user(params, opts \\ []) do
    with {:ok, attrs} <- parse_params(params),
         {:ok, user} <- insert_user(attrs) do
      if opts[:notify] == :welcome, do: send_welcome(user)
      {:ok, user}
    end
  end

  defp parse_params(params) do
    with {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         {:ok, role} <- parse_role(params["role"]) do
      {:ok,
       %{
         email: email,
         age: min(age, @max_age),
         role: role,
         nickname: params["nickname"] || email
       }}
    end
  end

  # The provider lowercases addresses before its uniqueness check, so match it here
  defp parse_email(email) when is_binary(email), do: {:ok, String.downcase(email)}
  defp parse_email(_email), do: {:error, {:invalid_field, "email"}}

  defp parse_age(text) when is_binary(text) do
    case Integer.parse(text) do
      {age, ""} when age >= @min_age -> {:ok, age}
      _ -> {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(_age), do: {:error, {:invalid_field, "age"}}

  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("editor"), do: {:ok, :editor}
  defp parse_role("viewer"), do: {:ok, :viewer}
  defp parse_role(other), do: {:error, {:unknown_role, other}}

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
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```
