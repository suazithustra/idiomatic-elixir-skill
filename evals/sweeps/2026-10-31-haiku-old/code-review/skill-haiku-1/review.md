# Review: `code-review-input.ex` (Accounts.UserImporter)

## Findings

1. **The age cap never applies.** Rule: assign the result of `if` (SKILL.md, "Assign the result of `if`, `case`, and `Enum` calls"). `if age > 120 do age = 120 end` rebinds `age` inside the block, so the outer `age` stays at its input value (for example 150). Fix: `age: min(age, @max_age)`.

2. **External input creates atoms.** Rule: convert external strings to atoms with explicit clauses. `role = String.to_atom(params["role"])` lets any caller add atoms to the VM's fixed atom table, and a missing `"role"` key crashes the function. Fix: `role_field/1` maps each accepted string to an atom and returns `{:error, {:invalid_field, "role"}}` for the rest.

3. **A catch-all `rescue` hides bugs.** Rule: return tuples for expected failures and raise only for bugs; never `rescue _ ->` around a whole function. `try ... rescue _ -> {:error, :invalid}` turns every exception, including programming errors, into the same answer. Fix: remove the `try`; `Integer.parse/1` returns `:error` for bad input instead of raising.

4. **Uniqueness is checked by hand.** Rule: changeset validation with `unique_constraint/3`. `if Repo.get_by(User, email: email) == nil do` runs a lookup before the insert, which can race with another insert and is not the database's check. Fix: `User.changeset/2` declares `unique_constraint(:email)`, and the database has a unique index on `email`. A duplicate then comes back as `{:error, changeset}`.

5. **The struct is inserted without a changeset.** Rule: validate input with changesets. `user = %User{email: email, age: age, role: role, nickname: nickname}` followed by `Repo.insert(user)` writes whatever was built, with no validation. Fix: `%User{} |> User.changeset(attrs) |> Repo.insert()`.

6. **The insert result has a catch-all clause.** Rule: match every expected shape and let unexpected ones crash. `_ -> {:error, :insert_failed}` also hides any new return value. Fix: `insert_user/1` returns the `Repo.insert/1` result unchanged, so `{:error, changeset}` reaches the caller.

7. **Required fields are read with `[]` and not checked one at a time.** Rule: match the required keys of string-keyed input, and give each missing or invalid field its own error. `params["email"] |> String.downcase()` and `String.to_integer(params["age"])` fail with an unclear error or a generic `:invalid`, and the caller cannot tell which field was wrong. The `age >= 18` check also returns the same `:invalid`. Fix: `string_field/2`, `age_field/1`, and `role_field/1` return `{:missing_field, key}` or `{:invalid_field, key}`, chained with `with`.

8. **The return shape depends on an option.** Rule: give each function one return shape. `if opts[:return_id], do: user.id, else: {:ok, user}` returns an integer in one mode and a tuple in the other. Fix: remove `:return_id`; the function always returns `{:ok, user}`, and callers that need the ID read `user.id`.

9. **Options overlap and are not validated.** Rule: use one atom-valued option instead of overlapping booleans, and validate options with `Keyword.validate!/2` documented under `## Options`. `opts[:notify] && !opts[:silent]` makes `silent` only meaningful when `notify` is set, and a misspelled option is ignored. Fix: `Keyword.validate!(opts, notify: false)`; `:silent` is dropped because not passing `:notify` already means no email. Callers that pass `silent:` now get an `ArgumentError`.

10. **Boolean operators on boolean values.** Rule: use `and`, `or`, `not` when the operands are booleans. `is_binary(email) && age >= 18` and `opts[:notify] && !opts[:silent]` use `&&` and `!`, which accept any value. Fix: the type check moves into `string_field/2`, and the remaining checks no longer need a boolean operator.

11. **Pipes that should not be pipes.** Rule: do not pipe a single step, and do not pipe into an anonymous function call. `params["email"] |> String.downcase()` pipes one step, and `greeting |> (fn text -> text <> " Enjoy your account." end).()` pipes into an anonymous function. Fix: `String.downcase(email)`, and one interpolated string for the greeting.

12. **Dot access is used on a struct through `Access`.** Rule: structs do not implement `Access`, so read struct fields with `user.name` or a pattern. `user[:name]` raises `UndefinedFunctionError`. Fix: `user.nickname`, which the import always sets. The greeting now uses the nickname, not a `:name` field; confirm that is the intended text.

13. **A bare `spawn` sends the welcome email.** Rule: supervise every long-lived process. `spawn(fn -> Mailer.deliver(welcome_email(user)) end)` has no supervisor, so a crash is lost and the process does not show in monitoring tools. Fix: `Task.Supervisor.start_child(Accounts.TaskSupervisor, ...)`. The `Accounts.TaskSupervisor` child must be added to the application's supervision tree.

14. **Magic numbers.** Rule: name magic numbers with module attributes. `120` and `18` appear inline. Fix: `@max_age 120` and `@min_age 18`.

15. **Comments carry documentation, and two restate the code.** Rule: comments explain why; module and function documentation goes in `@moduledoc` and `@doc`. `# This module imports users...` should be `@moduledoc`, `# Import a single user...` should be `@doc`, and `# Get the role from params` and `# send the email` restate the next line. Fix: the module and function text moves into `@moduledoc` and `@doc`, the two restating comments are deleted, and the reason comment about lowercasing addresses stays.

16. **One function holds the whole flow.** Rule: keep functions short and at one level of detail. `import_user/2` nests a `try`, two `if`s, a `case`, and another `if`. Fix: `import_user/2` runs three steps (`parse_params/1`, `insert_user/1`, `send_welcome/1`) in a `with`, and each step is a private function.

## Improved version

Checked here: `mix format --check-formatted` passes, and the module compiles and runs against stub `User`, `Repo`, and `Mailer` modules. It has not been run against the real project's `User` schema, `Repo`, or `Mailer`. The roles `:admin`, `:editor`, and `:viewer` are placeholders; replace them with the roles the application defines.

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from external CSV (comma-separated values) and JSON
  (JavaScript Object Notation) sources.
  """

  alias Accounts.{Repo, User}

  @max_age 120
  @min_age 18

  @doc """
  Imports one user from string-keyed params.

  Returns `{:ok, user}`, or `{:error, reason}` where `reason` is
  `{:missing_field, key}`, `{:invalid_field, key}`, or a changeset when
  the database rejects the row.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, attrs} <- parse_params(params),
         {:ok, user} <- insert_user(attrs) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  defp parse_params(params) do
    with {:ok, email} <- string_field(params, "email"),
         {:ok, age} <- age_field(params),
         {:ok, role} <- role_field(params) do
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

  defp age_field(params) do
    case string_field(params, "age") do
      {:ok, text} -> parse_age(text)
      {:error, _reason} = error -> error
    end
  end

  defp parse_age(text) do
    case Integer.parse(text) do
      {age, ""} when age >= @min_age -> {:ok, age}
      _ -> {:error, {:invalid_field, "age"}}
    end
  end

  # Placeholder roles: replace with the roles the application defines
  defp role_field(params) do
    case string_field(params, "role") do
      {:ok, "admin"} -> {:ok, :admin}
      {:ok, "editor"} -> {:ok, :editor}
      {:ok, "viewer"} -> {:ok, :viewer}
      {:ok, _other} -> {:error, {:invalid_field, "role"}}
      {:error, _reason} = error -> error
    end
  end

  defp insert_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp send_welcome(user) do
    message = welcome_text(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(message) end)
  end

  defp welcome_text(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```
