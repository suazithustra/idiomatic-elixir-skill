# Review: `Accounts.UserImporter`

## Findings

1. Welcome emails never send. `welcome_email/1` reads `user[:name]`, but a struct does not support `[]` access, so the spawned process raises `UndefinedFunctionError` and the caller sees no error. Rule: "Read required keys with `map.key` or a pattern" (SKILL.md, Pattern matching). Fix: read `user.nickname`, the field the import already sets. The struct in this module has no `:name` field.

2. The age cap never applies. `if age > 120 do age = 120 end` rebinds `age` inside the `if`, and the new value does not leave the block, so a user aged 150 is saved as 150. Rule: "Assign the result of `if`, `case`, and `Enum` calls" (SKILL.md, Control flow). Fix: `age = min(age, @max_age)`, applied in the changeset.

3. A taken email is reported as `:invalid`, and the check is a race. `if Repo.get_by(User, email: email) == nil do` looks up the address and then inserts, so two imports of the same address running at once can both pass the check. A taken email also comes back as `{:error, :invalid}`. Rule: "Validate input with changesets" (references/ecto-phoenix.md), which names `unique_constraint/3`. Fix: remove the lookup and declare `unique_constraint(:email)`, which turns the database's unique-index error into a changeset error. This needs a unique index on the email column.

4. The insert bypasses validation. `user = %User{email: email, age: age, role: role, nickname: nickname}` followed by `Repo.insert(user)` stores whatever the params contain. Rule: "Validate input with changesets" (references/ecto-phoenix.md). Fix: build a changeset with `cast/3`, `validate_required/2`, and `validate_number/3`, and pass it to `Repo.insert/1`.

5. One `rescue` catches every error in the function. `rescue _ -> {:error, :invalid}` turns a crash in the code into the same answer as bad input, so bugs stay hidden. Rule: "Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs" (SKILL.md, Control flow): never `rescue _ ->` around a whole function. Fix: remove the `try` and `rescue`.

6. Errors collapse into two reasons. `{:error, :invalid}` covers a missing email, an age under 18, a non-numeric age, and a taken email. The `_ ->` clause maps every insert failure to `{:error, :insert_failed}`. Rule: "Match every expected shape and let unexpected ones crash" (SKILL.md, Pattern matching), which says different failures need different reasons. Fix: return the changeset, so its errors name each field.

7. `String.to_integer/1` raises on bad input and the raise is caught by the `rescue`. `age = String.to_integer(params["age"])` raises on `"abc"`. Rule: "Return `{:ok, value}` ... raise only for bugs": call the non-raising version. Fix: `cast/3` converts the string, and a bad value becomes a changeset error.

8. The role string becomes an atom. `String.to_atom(params["role"])` creates an atom from outside input. Atoms are never freed, and the Erlang virtual machine (the runtime that runs Elixir) has a fixed atom limit, so a flood of made-up roles can crash the node. A missing role also raises, and it does so outside the `try`. Rule: "Convert external strings to atoms with explicit clauses" (SKILL.md, Pattern matching). Fix: declare `role` as an `Ecto.Enum` field in the schema, so `cast/3` converts only the listed values.

9. The option `return_id` changes the return type. `if opts[:return_id], do: user.id, else: {:ok, user}` returns a bare integer in one mode and a tuple in the other. Rule: "Give each function one return shape" (SKILL.md, Modeling data). Fix: always return `{:ok, user}`. Callers that need the id read `user.id`, and the `return_id` option goes away.

10. Two overlapping booleans. `opts[:notify] && !opts[:silent]` needs both options, because `silent` only cancels `notify`. Rule: "Use one atom-valued field or option instead of overlapping booleans" (SKILL.md, Modeling data). Fix: keep `notify: true` alone, which is the rule's own example. The `silent` option goes away, so callers that pass `silent: true` must drop it.

11. `&&` joins two booleans. `if is_binary(email) && age >= 18 do` has two boolean operands. Rule: "Use `and`, `or`, `not` when the operands are booleans" (SKILL.md, Control flow). Fix: the check moves into the changeset with `validate_required/2` and `validate_number/3`, so the line disappears. If the check stays in place, use `and`.

12. Welcome email is sent from an unsupervised process. `spawn(fn -> Mailer.deliver(welcome_email(user)) end)` starts a process that no supervisor tracks, so a crash leaves no trace. The closure also copies the whole `user` struct. Rules: "Supervise every long-lived process" and "Send processes only the data they need" (references/processes.md). Fix: build the email first, then `Task.Supervisor.start_child/2`. This assumes `Accounts.TaskSupervisor` is in the application's supervision tree.

13. Pipe into an anonymous function. `greeting |> (fn text -> text <> " Enjoy your account." end).()` is the form the rule forbids. Rule: "Do not pipe into an anonymous function call" (SKILL.md, Readability). Fix: one interpolated string, `"Hi #{user.nickname}, welcome! Enjoy your account."`.

14. Single-step pipe. `params["email"] |> String.downcase()` pipes one call. Rule: "Do not pipe a single step" (SKILL.md, Readability). Fix: `String.downcase(params["email"])`. The improved version moves this into `Changeset.update_change/3`.

15. Documentation sits in comments, and some comments restate the code. `# This module imports ...` and `# Import a single user ...` should be `@moduledoc` and `@doc`. `# Get the role from params` and `# send the email` repeat what the next line says. Rule: "Comments explain why; documentation goes in `@moduledoc` and `@doc`" (SKILL.md, Readability). Fix: move the two descriptions into the attributes and delete the restating comments. The comment about lowercasing addresses stays, because it gives the reason.

## Assumptions in the improved version

- `User` has the fields `email`, `age`, `role`, and `nickname`, and declares `role` as `Ecto.Enum` with the valid roles. The role names in the original code are not visible here.
- A unique index exists on the email column of the users table.
- `Accounts.TaskSupervisor` is started in the application's supervision tree.
- The welcome greeting uses `nickname`, since the struct in this module has no `name` field.
- Callers that passed `return_id` or `silent` must update their code.
- The improved module was not compiled or run through `mix format`, because the `User` schema and the other project modules are not available here. Run `mix format --check-formatted` and `mix compile` in the project before use.

## Improved version

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV (comma-separated values) or JSON (JavaScript Object Notation) source.
  """

  alias Accounts.{Repo, User}
  alias Ecto.Changeset

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from string-keyed params.

  Returns `{:ok, user}`, or `{:error, changeset}` when a field is invalid or the
  email is already taken.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    changeset = user_changeset(params)

    with {:ok, user} <- Repo.insert(changeset) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  defp user_changeset(params) do
    # The provider lowercases addresses before its uniqueness check, so match it here
    %User{}
    |> Changeset.cast(params, [:email, :age, :role, :nickname])
    |> Changeset.update_change(:email, &String.downcase/1)
    |> Changeset.update_change(:age, &min(&1, @max_age))
    |> Changeset.validate_required([:email, :age, :role])
    |> Changeset.validate_number(:age, greater_than_or_equal_to: @min_age)
    |> Changeset.unique_constraint(:email)
    |> put_default_nickname()
  end

  defp put_default_nickname(changeset) do
    if Changeset.get_field(changeset, :nickname) do
      changeset
    else
      Changeset.put_change(changeset, :nickname, Changeset.get_field(changeset, :email))
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
