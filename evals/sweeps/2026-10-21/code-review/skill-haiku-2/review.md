# Review: `Accounts.UserImporter`

Rules are from `references/*.md` and `SKILL.md` of the idiomatic-elixir skill. Findings are in order of severity.

1. Line 38–39, `rescue _ -> {:error, :invalid}`. This catches every error in the function, including bugs in the insert and the welcome email code, so a broken import looks like bad input. Rule: "never `rescue _ ->` or `rescue e ->` around a whole function." Fix: remove the `try` and return tuples for expected failures (see the improved code).

2. Line 15–17, `if age > 120 do age = 120 end`. The clamp never takes effect. The inner `age` is local to the `if`, so an age of 150 is stored as 150. Rule: "Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it". Fix: `min(value, @max_age)`.

3. Line 49, `name = user[:name] || "there"`. `user` is a `%User{}` struct, and structs do not implement Access (the `[]` lookup syntax). Every welcome email raises `UndefinedFunctionError` here. The error happens inside a spawned process, so nothing reports it and no email is sent. Rule: "Structs do not implement `Access`: `user[:name]` raises `UndefinedFunctionError`". Fix: use `user.nickname`, which the import always sets.

4. Line 45, `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`. A bare process has no supervisor, so a crash is neither restarted nor logged in a supervised way. Rule: "A bare `spawn/1` or `Task.start/1` outside a supervisor has none of this." Fix: `Task.Supervisor.start_child/2` under a named task supervisor. The application must start `Accounts.TaskSupervisor` (assumed name).

5. Line 13, `age = String.to_integer(params["age"])`. A non-numeric age raises, and the blanket rescue turns that into `:invalid`. Rule: "Do not wrap a raising call in `try/rescue` to get a tuple. Call the non-raising version: `File.read/1`, `Integer.parse/1`". Fix: `parse_age/1` with `Integer.parse/1` and tagged error tuples.

6. Line 8, `role = String.to_atom(params["role"])`. Every new role string from the input creates a new atom. Atoms are never freed, so input can exhaust the atom table and crash the Erlang VM (the runtime Elixir runs on). A missing role also raises. Rule: "Convert external strings to atoms with explicit clauses". Fix: `parse_role/1` with one clause per accepted role. The role list (`admin`, `editor`, `viewer`) is a placeholder; use the real list.

7. Line 12, 13, 15, and 21, hand-written checks. The module checks fields by hand, and the `is_binary(email)` check on line 21 cannot catch a missing email, because line 12 already called `String.downcase/1` on it, which raises first. Rule: "Cast and validate external input with `Ecto.Changeset` (`cast/3`, `validate_required/2`, `validate_number/3`, `validate_inclusion/3`) instead of checking fields by hand." (`references/ecto-phoenix.md`, "Validate input with changesets".) Fix: pass the attributes to `User.changeset/2`. The fix assumes that function exists. If it does not, add it with `validate_required/2` for email, age, and role, and `validate_number(:age, greater_than_or_equal_to: 18)`.

8. Line 32–33, `_ -> {:error, :insert_failed}`. The catch-all drops the reason, so a caller cannot tell a validation failure from a database failure. Rule: "A `_ ->` clause after `{:ok, value}` turns every other return value, including ones added later, into the same error and hides bugs." Fix: `{:error, changeset} -> {:error, {:invalid_user, changeset}}`.

9. Line 26, `if opts[:notify] && !opts[:silent] do`. The two options overlap: `notify: true, silent: true` has no clear meaning, and `silent` overrides `notify` in a way the reader must work out. Rule: "Use one atom-valued field or option instead of overlapping booleans". Fix: a single `welcome_email: :send | :skip` option. This removes `notify` and `silent`, so existing callers must change.

10. Line 30, `if opts[:return_id], do: user.id, else: {:ok, user}`. The return type depends on an option, so callers get a bare id in one mode and a tuple in the other. Rule: "Options must not change what a function returns." Fix: `import_user/2` always returns a tuple, and a new `import_user_id/2` returns `{:ok, id}`.

11. Line 6, `def import_user(params, opts \\ []) do`. The function has no `@doc`, and its options are not checked, so a misspelled option such as `notfy: true` is silently ignored. Rule: "check them with `Keyword.validate!/2`, and document each one under `## Options` in `@doc`." Fix: `Keyword.validate!/2` and a `@doc` with an `## Options` section.

12. Line 21, `if is_binary(email) && age >= 18 do`, and line 26, `!opts[:silent]`. `&&` and `!` accept any value, while `and` and `not` check that their operands are booleans. Rule: "Use `and`, `or`, `not` when the operands are booleans". Fix: both lines are removed by findings 7 and 9. Use `and` in any boolean check that remains.

13. Line 12, `email = params["email"] |> String.downcase()`. This pipe has one step. Rule: "Do not pipe a single step: write `String.trim(name)`, not `name |> String.trim()`." Fix: `parse_email/1`, which also handles a missing email (see finding 7).

14. Line 15 and 21, the numbers `120` and `18`. Rule: "Name magic numbers with module attributes". Fix: `@max_age 120`. The minimum age of 18 moves into the changeset (finding 7).

15. Line 51, `greeting |> (fn text -> text <> " Enjoy your account." end).()`. Rule: "Do not pipe into an anonymous function call (`|> (fn x -> ... end).()`)." Fix: one interpolated string.

16. Line 2, 5, 7, and 44, comments. Line 2 describes the module in a comment, where `@moduledoc` belongs. Lines 5, 7, and 44 restate the code (`# Get the role from params`, `# send the email`). Line 11 explains why the email is lowercased, so keep it. Rule: "Delete comments that restate the code" and "Document modules and public functions with `@moduledoc` and `@doc`, not with comments above them." Fix: `@moduledoc`, and delete the restating comments.

17. Line 6–41, `import_user/2`. The function is 35 lines with three levels of nesting, and it mixes parsing, validation, insertion, and email sending. Rule: "Keep functions short and at one level of detail". Fix: split it into `parse_params/1`, `insert_user/1`, and `send_welcome/1`.

## Improved code

Behavior changes: `notify`, `silent`, and `return_id` are no longer accepted; callers must switch to `welcome_email:` and `import_user_id/2`. Errors are now `{:missing_field, key}`, `{:invalid_field, key}`, or `{:invalid_user, changeset}` instead of `:invalid` and `:insert_failed`.

Assumptions to check: `User.changeset/2` exists and enforces the 18-year minimum; `Accounts.TaskSupervisor` is started in the application; the role list matches the real one; `Mailer.deliver/1` accepts the message string as the original code did. I did not change the Mailer call, so this review does not confirm it works.

The improved module compiles, and a smoke test with stub `User`, `Repo`, and `Mailer` modules gave the expected results for clamping, invalid age, missing email, invalid role, the under-18 changeset error, welcome email sending, and `import_user_id/2`. `mix format --check-formatted` passes.

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV (comma-separated values) or JSON (JavaScript Object Notation) source.
  """

  alias Accounts.{Repo, User}

  @max_age 120

  @doc """
  Imports a single user from string-keyed params.

  Returns `{:ok, user}` or `{:error, reason}`.

  ## Options

    * `:welcome_email` - `:send` sends a welcome email after the insert,
      `:skip` sends none. Defaults to `:skip`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, welcome_email: :skip)

    with {:ok, attrs} <- parse_params(params),
         {:ok, user} <- insert_user(attrs) do
      if opts[:welcome_email] == :send, do: send_welcome(user)
      {:ok, user}
    end
  end

  @doc """
  Same as `import_user/2`, but returns `{:ok, id}` instead of `{:ok, user}`.
  """
  def import_user_id(params, opts \\ []) do
    with {:ok, user} <- import_user(params, opts), do: {:ok, user.id}
  end

  defp parse_params(params) do
    with {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         {:ok, role} <- parse_role(params["role"]) do
      {:ok,
       %{
         email: email,
         age: age,
         role: role,
         nickname: params["nickname"] || email
       }}
    end
  end

  # The provider lowercases addresses before its uniqueness check, so match it here
  defp parse_email(email) when is_binary(email), do: {:ok, String.downcase(email)}
  defp parse_email(nil), do: {:error, {:missing_field, "email"}}
  defp parse_email(_email), do: {:error, {:invalid_field, "email"}}

  defp parse_age(nil), do: {:error, {:missing_field, "age"}}

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {value, ""} -> {:ok, min(value, @max_age)}
      _ -> {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(_age), do: {:error, {:invalid_field, "age"}}

  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("editor"), do: {:ok, :editor}
  defp parse_role("viewer"), do: {:ok, :viewer}
  defp parse_role(_role), do: {:error, {:invalid_field, "role"}}

  defp insert_user(attrs) do
    changeset = User.changeset(%User{}, attrs)

    case Repo.insert(changeset) do
      {:ok, user} -> {:ok, user}
      {:error, changeset} -> {:error, {:invalid_user, changeset}}
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
