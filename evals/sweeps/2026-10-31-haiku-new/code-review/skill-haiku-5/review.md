# Review: `Accounts.UserImporter`

Rules are quoted from `idiomatic-elixir/SKILL.md` (SKILL.md) or `references/processes.md` and `references/ecto-phoenix.md`, by section heading.

## Findings, most severe first

1. The welcome email is never sent. `user[:name]` raises `UndefinedFunctionError` because structs do not implement Access (the `[]` lookup). The error happens inside the `spawn` process, so nothing reports it. Rule: SKILL.md, "Read required keys with `map.key` or a pattern; keep `map[:key]` for optional keys", which says "Structs do not implement `Access`: `user[:name]` raises `UndefinedFunctionError`". Quote: `name = user[:name] || "there"`. Fix: read the field this module sets, `user.nickname`.

2. The age cap never runs. A variable set inside `if` is local to that block, so `age` keeps its old value and ages above 120 are stored. Rule: SKILL.md, "Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it". Quote: `if age > 120 do` / `age = 120`. Fix: `min(age, @max_age)`.

3. Input becomes an atom (a named constant that the VM (virtual machine) never frees), so a caller can fill the atom table and crash the node. Rule: SKILL.md, "Convert external strings to atoms with explicit clauses". Quote: `role = String.to_atom(params["role"])`. Fix: declare `role` as an `Ecto.Enum` field and let `cast/3` map the string.

4. The duplicate check is a lookup followed by a raw insert. Two imports of the same email can both pass the lookup, and the raw struct skips validation. Rule: references/ecto-phoenix.md, "Validate input with changesets", which says to declare database constraints with `unique_constraint/3`. Quote: `if Repo.get_by(User, email: email) == nil do`. Fix: build the record with `User.changeset/2` and let the unique index return `{:error, changeset}`.

5. A `rescue _ ->` around the whole function turns every error, including bugs, into `{:error, :invalid}`. Rule: SKILL.md, "Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs", which says to "never `rescue _ ->` or `rescue e ->` around a whole function". Quote: `_ -> {:error, :invalid}`. Fix: remove the `try`, and use `Integer.parse/1` in place of `String.to_integer/1`, which raises.

6. A catch-all clause hides why the insert failed. Rule: SKILL.md, "Match every expected shape and let unexpected ones crash", which says a `_ ->` clause "turns every other return value ... into the same error". Quote: `_ ->` / `{:error, :insert_failed}`. Fix: let `{:error, changeset}` pass through unchanged.

7. A bare `spawn/1` runs the email with no supervisor, so a crash is not logged or restarted. Rule: references/processes.md, "Supervise every long-lived process", which says "A bare `spawn/1` or `Task.start/1` outside a supervisor has none of this." Quote: `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`. Fix: `Task.Supervisor.start_child/2` under `Accounts.TaskSupervisor`, which must be in the application's supervision tree.

8. The `return_id` option changes what the function returns, so callers cannot know the return shape. Rule: SKILL.md, "Give each function one return shape", which says "Options must not change what a function returns." Quote: `if opts[:return_id], do: user.id, else: {:ok, user}`. Fix: a second function, `import_user_id/2`.

9. `notify` and `silent` are overlapping booleans. `silent: true` only ever cancels `notify: true`, so it is the same as `notify: false`. Rule: SKILL.md, "Use one atom-valued field or option instead of overlapping booleans". Quote: `if opts[:notify] && !opts[:silent] do`. Fix: keep `notify` and drop `silent`.

10. Options are read but never checked, so a misspelled option is ignored silently. Rule: SKILL.md, "Group related parameters", which says to check options with `Keyword.validate!/2`. Quote: `def import_user(params, opts \\ []) do`. Fix: `opts = Keyword.validate!(opts, notify: false)`.

11. The numbers 18 and 120 are written inline. Rule: SKILL.md, "Name magic numbers with module attributes". Quote: `if is_binary(email) && age >= 18 do`. Fix: `@min_age 18` and `@max_age 120`.

12. Four levels of nesting (`try`, `if`, `if`, `case`, `if`) make the happy path hard to follow. Rule: SKILL.md, "Keep functions short and at one level of detail", which says to move an inner `case`, `if`, or `with` "into a named private function". Quote: `if Repo.get_by(User, email: email) == nil do`, inside the `if is_binary(email)` block. Fix: a `with` over private functions `parse_age/1` and `insert_user/1`.

13. A pipe runs into an anonymous function. Rule: SKILL.md, "Write pipelines that start with a value and read top to bottom", which says "Do not pipe into an anonymous function call." Quote: `greeting |> (fn text -> text <> " Enjoy your account." end).()`. Fix: one string with interpolation.

14. A pipe has one step. Rule: SKILL.md, the same section, which says "Do not pipe a single step." Quote: `email = params["email"] |> String.downcase()`. Fix: moved into `User.changeset/2`, where the downcase belongs next to the uniqueness check, as the removed comment said.

15. `&&` is used on booleans. Rule: SKILL.md, "Use `and`, `or`, `not` when the operands are booleans". Quote: `if is_binary(email) && age >= 18 do`. Fix: the checks move into `parse_age/1` and the changeset.

16. The module and public function use comments where `@moduledoc` and `@doc` belong, and some comments restate the code. Rule: SKILL.md, "Comments explain why; documentation goes in `@moduledoc` and `@doc`", which says to "Delete comments that restate the code". Quote: `# This module imports users from an external CSV/JSON source` and `# Get the role from params`. Fix: `@moduledoc` and `@doc`, and delete the restating comments.

## Improved version

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external source, such as a CSV (comma-separated values)
  or JSON (JavaScript Object Notation) file.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports one user from string-keyed params and returns `{:ok, user}` or
  `{:error, reason}`.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, age} <- parse_age(params["age"]),
         {:ok, user} <- insert_user(Map.put(params, "age", age)) do
      if opts[:notify], do: send_welcome(user)

      {:ok, user}
    end
  end

  @doc """
  Like `import_user/2`, but returns `{:ok, id}` instead of the user.
  """
  def import_user_id(params, opts \\ []) do
    with {:ok, user} <- import_user(params, opts), do: {:ok, user.id}
  end

  defp parse_age(nil), do: {:error, {:missing_field, "age"}}

  defp parse_age(text) when is_binary(text) do
    case Integer.parse(text) do
      {age, ""} when age >= @min_age -> {:ok, min(age, @max_age)}
      _ -> {:error, {:invalid_field, "age"}}
    end
  end

  defp insert_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp send_welcome(user) do
    message = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(message) end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

## What the improved version assumes

- `User.changeset/2` exists. It must cast `email`, `nickname`, and `role`; downcase the email (keep the comment about the provider's uniqueness check there); default `nickname` to the email; validate `email` as required; call `unique_constraint(:email)`; and declare `role` as `Ecto.Enum`.
- `Accounts.TaskSupervisor` is started in the application's supervision tree.
- `import_user/2` now returns `{:error, changeset}` for database and validation failures, and `{:error, {:missing_field, "age"}}` or `{:error, {:invalid_field, "age"}}` for a bad age. Callers that matched `{:error, :invalid}` or `{:error, :insert_failed}` must change.
- Ages above 120 are capped at 120. The original code meant to do this but never did. Confirm that capping, rather than rejecting, is the intent.
- The `silent:` option is removed. Callers that passed `notify: true` and `silent: true` together will now get the welcome email, which they did not get before, so check their calls.
- The greeting reads `nickname`, which the import sets, instead of `name`, which it never set. The welcome email was never sent before this change (finding 1).
