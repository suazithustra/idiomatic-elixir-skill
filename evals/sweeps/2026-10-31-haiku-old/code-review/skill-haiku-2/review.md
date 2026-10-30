# Review: `Accounts.UserImporter`

## Findings

1. **The age cap does nothing.** Lines 15–17 rebind `age` inside an `if`, and the new value stays inside that block, so an age of 150 is kept as 150. Rule: "Assign the result of `if`, `case`, and `Enum` calls". Fix: `min(age, @max_age)` in `parse_age/1`.

2. **The welcome email never sends for a user with a `name` field.** Line 53, `user[:name]`, raises `UndefinedFunctionError` because structs do not implement Access. The call happens inside the spawned process, so the user is inserted, no email goes out, and nothing reports the error. Rule: "Structs do not implement `Access`". Fix: `user.nickname`, which the struct already sets.

3. **Input strings become atoms.** Line 8, `String.to_atom(params["role"])`, lets whoever controls the input fill the atom table (the VM's limit is 1,048,576 atoms by default), and a missing role raises outside the `try`. Rule: "Convert external strings to atoms with explicit clauses". Fix: `parse_role/1` with one clause per accepted role.

4. **A rescue-all hides bugs.** Lines 10, 13, and 42–43 wrap `String.to_integer/1`, which raises on `"abc"`, and a `rescue _ ->` that turns every exception, including programming errors, into `{:error, :invalid}`. Rule: "Do not wrap a raising call in `try/rescue`" and "never `rescue _ ->` around a whole function". Fix: `Integer.parse/1` in a function clause, and no `try`.

5. **Every failure becomes one atom.** Lines 33–40 return `{:error, :invalid}` for a bad age, a bad email, a taken email, and a young user alike, so callers cannot tell them apart. The nesting of `if` and `case` four levels deep is also what makes this hard to follow. Rule: "Return `{:ok, value}` or `{:error, reason}` for expected failures" with tagged tuples, and "Chain fallible steps with `with`". Fix: a `with` over small parse functions, each returning `{:error, {:invalid_field, name}}`.

6. **The duplicate check races and the struct skips validation.** Line 24, `Repo.get_by(User, email: email) == nil`, followed by an insert, lets two imports of the same email both pass the check. Line 22 builds a `%User{}` and inserts it with no changeset, so nothing is validated. Rule (`references/ecto-phoenix.md`): cast through a changeset and declare `unique_constraint/3`, so a violation returns `{:error, changeset}`. Fix: `User.changeset/2` with `unique_constraint(:email)`. This needs a unique index on the users' email column; the current code relies on the lookup alone, so that index may not exist yet.

7. **A catch-all hides insert errors.** Line 33, `_ -> {:error, :insert_failed}`, drops the changeset that explains the failure. Rule: "Match every expected shape and let unexpected ones crash". Fix: return `{:error, changeset}` from `insert_user/4`.

8. **An option changes the return shape.** Line 31, `if opts[:return_id], do: user.id, else: {:ok, user}`, makes the function return an integer in one mode and a tuple in another. Rule: "Give each function one return shape". Fix: remove the option; callers read `user.id` from `{:ok, user}`.

9. **Two options overlap, and no option is checked.** Line 27, `opts[:notify] && !opts[:silent]`, uses `silent` only to cancel `notify`, so `silent` adds nothing. A misspelled option is also ignored without a message. Rule: "Use one atom-valued field or option instead of overlapping booleans" and "check them with `Keyword.validate!/2`". Fix: drop `silent`, and validate the options with `Keyword.validate!/2`.

10. **The welcome email is an unsupervised process.** Line 49, `spawn(fn -> ... end)`, has no supervisor, so a crash goes unlogged and nothing restarts it, and the closure copies the whole `user` into the new process. Rule (`references/processes.md`): "Task.Supervisor.start_child/2" for fire-and-forget work. Fix: build the email in the caller and start the task under a supervisor. This needs a `MyApp.TaskSupervisor` in the application's supervision tree; the name is my assumption.

11. **Pipes where a plain call reads better.** Line 12, `params["email"] |> String.downcase()`, pipes a single step. Line 55, `greeting |> (fn text -> ... end).()`, pipes into an anonymous function call. Rule: "Do not pipe a single step" and "Do not pipe into an anonymous function call". Fix: move the downcase into `parse_email/1`, and build the greeting as one string.

12. **`&&` is used on booleans.** Lines 21 and 27 use `&&` on boolean values. Rule: "Use `and`, `or`, `not` when the operands are booleans". Fix: the `is_binary/1` check moves into the `parse_email/1` guard, and the `silent` check goes with finding 9.

13. **Comments are in the wrong place.** Lines 2, 5, and 48 document the module and functions with `#` comments, where the rule asks for `@moduledoc` and `@doc`. Lines 7, 48, and 5 restate the code. Line 11 explains why the email is lowercased, so it stays. Rule: "Comments explain why; documentation goes in `@moduledoc` and `@doc`". Fix: `@moduledoc`, a `@doc` with `## Options`, and the one comment that explains a reason.

## Improved version

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV (comma-separated values) or JSON
  (JavaScript Object Notation) source.
  """

  alias Accounts.{Repo, User}

  @adult_age 18
  @max_age 120

  @doc """
  Imports one user from string-keyed params.

  Returns `{:ok, user}`, or `{:error, reason}` where `reason` is
  `{:invalid_field, field}` or the changeset from a failed insert, such as
  one for an email that is already taken.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, role} <- parse_role(params["role"]),
         {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         :ok <- ensure_adult(age),
         {:ok, user} <- insert_user(params, email, age, role) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("editor"), do: {:ok, :editor}
  defp parse_role("member"), do: {:ok, :member}
  defp parse_role(_role), do: {:error, {:invalid_field, "role"}}

  # The provider lowercases addresses before its uniqueness check, so match it here
  defp parse_email(email) when is_binary(email), do: {:ok, String.downcase(email)}
  defp parse_email(_email), do: {:error, {:invalid_field, "email"}}

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {parsed, ""} -> {:ok, min(parsed, @max_age)}
      _other -> {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(_age), do: {:error, {:invalid_field, "age"}}

  defp ensure_adult(age) when age >= @adult_age, do: :ok
  defp ensure_adult(_age), do: {:error, {:invalid_field, "age"}}

  defp insert_user(params, email, age, role) do
    attrs = %{
      email: email,
      age: age,
      role: role,
      nickname: params["nickname"] || email
    }

    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp send_welcome(user) do
    email = welcome_email(user)
    Task.Supervisor.start_child(MyApp.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user), do: "Hi #{user.nickname}, welcome! Enjoy your account."
end
```

## Changes the caller must know about

- `User.changeset/2` must exist and call `unique_constraint(:email)`, and the database needs a unique index on the email column.
- `MyApp.TaskSupervisor` must be in the supervision tree. The name is assumed.
- The role names `"admin"`, `"editor"`, and `"member"` are placeholders. Replace them with the app's real roles.
- The greeting uses `nickname`, which defaults to the email. The old code read `name`, which is not a field of the struct shown, so the greeting for users without a nickname changes.
- Callers that pass `return_id:` or `silent:` now get an `ArgumentError` from `Keyword.validate!/2`. Callers that used `return_id: true` should read `user.id` from `{:ok, user}`.
- Errors are now `{:invalid_field, name}` or a changeset, where the old code returned `:invalid` or `:insert_failed`.
