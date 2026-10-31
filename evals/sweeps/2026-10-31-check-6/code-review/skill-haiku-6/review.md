# Review: `Accounts.UserImporter`

## Findings

1. **Input becomes an atom (line 8).** Rule: convert external strings to atoms with explicit clauses. `role = String.to_atom(params["role"])` lets any caller add atoms to the VM's fixed atom table, and a missing `"role"` key raises before the `try`. Fix: `parse_role/1` with one clause per accepted role and an `{:error, {:unknown_role, other}}` fallback.

2. **Whole function wrapped in `rescue _ ->` (lines 10, 42-43).** Rule: return tuples for expected failures; rescue only specific exceptions, never `rescue _` around a whole function. Any bug or database error inside the body is reported as `{:error, :invalid}`. Fix: remove the `try` and the `rescue`.

3. **Raising parser for input (line 13).** Rule: call the non-raising version instead of wrapping a raising call. `String.to_integer(params["age"])` raises on `"abc"`. Fix: `Integer.parse/1`, matching `{age, ""}`.

4. **Age clamp never applies (lines 15-17).** Rule: assign the result of `if`; rebinding inside a block does not escape it. `age = 120` is local to the `if`, so an age of 150 is stored as 150. Fix: `min(age, @max_age)`, which is what the code meant to do. Stored ages above 120 now become 120.

5. **Catch-all after `Repo.insert` (lines 25-34).** Rule: match every expected shape and let unexpected ones crash. `_ -> {:error, :insert_failed}` hides every other return value. Fix: match `{:ok, user}` and `{:error, %Ecto.Changeset{}}` explicitly.

6. **Every failure becomes `:invalid` (lines 37, 40, 43).** Rule: different failures need different reasons. A caller cannot tell an underage user from a bad email or a taken address. Fix: `:underage`, `{:invalid_field, key}`, `:email_taken`, and `{:invalid_user, changeset}` as separate reasons.

7. **Check-then-insert with a raw struct (lines 22, 24-25).** Rule: validate input with changesets and declare constraints with `unique_constraint/3`. `Repo.get_by(User, email: email) == nil` followed by `Repo.insert(user)` has a race: two imports of the same address can both pass the check. The raw `%User{}` also skips validation, and a constraint violation raises. Fix: build a changeset with `User.import_changeset/2`, which casts, validates, and calls `unique_constraint(:email)`, then map the unique violation to `:email_taken`. This also removes the separate lookup query.

8. **Option changes the return shape (line 31).** Rule: give each function one return shape. With `return_id: true`, the function returns an integer, and otherwise a tuple. Fix: always return `{:ok, user}`; callers that need the ID read `user.id`.

9. **Two overlapping boolean options (line 27).** Rule: use one atom-valued option instead of overlapping booleans. `notify: true, silent: true` is a combination with no clear meaning, and `opts[:notify] && !opts[:silent]` depends on it. Fix: `welcome: :email | :none`, validated with `Keyword.validate!/2`.

10. **`&&` and `!` on booleans (line 21).** Rule: use `and`, `or`, `not` when the operands are booleans. `is_binary(email)` is also dead code here, because `String.downcase/1` on a non-string already raised on line 12. Fix: the `email_field/1` clause with a guard replaces both checks.

11. **Nesting four levels deep inside `try` (lines 15-44).** Rule: keep functions short and at one level of detail; chain fallible steps with `with`. Each step returns `{:ok, value}` or `{:error, reason}` from a small private function, and `with` passes errors through.

12. **Struct read with `[]` (line 53).** Rule: structs do not implement `Access`. `user[:name]` raises `UndefinedFunctionError`. The struct built on line 22 has no `name` field, only `nickname`. Fix: `user.nickname`, which is never `nil` because it falls back to the email.

13. **Pipe into an anonymous function (line 55).** Rule: do not pipe into an anonymous function; use interpolation for string building. `greeting |> (fn text -> ... end).()` is hard to read, and the `<>` chain on line 54 is the same string built in two steps. Fix: one interpolated string.

14. **Pipe with one step (line 12).** Rule: do not pipe a single step. `params["email"] |> String.downcase()` is `String.downcase(params["email"])`.

15. **Bare `spawn` for the welcome email (line 49).** Rule: supervise every long-lived process; fire-and-forget work goes through `Task.Supervisor.start_child/2`. A bare `spawn` has no supervisor, so a crash in the mailer is lost, and the process does not appear in monitoring tools. Fix: `Task.Supervisor.start_child/4` under `Accounts.TaskSupervisor`, with the message built first.

16. **Comments restate the code; no `@doc` (lines 2, 5, 7, 48).** Rule: comments explain why; documentation goes in `@moduledoc` and `@doc`. `# Get the role from params` and `# send the email` say what the next line does. The module comment belongs in `@moduledoc`, and the public `import_user/2` has no `@doc` describing its options and reasons. The comment on line 11 explains a reason, so it stays.

## Improved version

Also in `review.md`'s code section below. The code applies every finding above.

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from string-keyed `params`.

  Returns `{:ok, user}`, or `{:error, reason}` where `reason` is one of
  `{:invalid_field, key}`, `{:unknown_role, value}`, `:underage`,
  `:email_taken`, or `{:invalid_user, changeset}`.

  ## Options

    * `:welcome` - `:email` sends a welcome email after the insert, `:none`
      sends nothing. Defaults to `:none`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, welcome: :none)

    with {:ok, role} <- parse_role(params["role"]),
         {:ok, email} <- email_field(params),
         {:ok, age} <- age_field(params),
         {:ok, age} <- clamp_adult_age(age),
         attrs = %{email: email, age: age, role: role, nickname: params["nickname"] || email},
         {:ok, user} <- insert_user(attrs) do
      if opts[:welcome] == :email, do: send_welcome(user)
      {:ok, user}
    end
  end

  # The roles the application defines. Replace these with the real list.
  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("editor"), do: {:ok, :editor}
  defp parse_role("member"), do: {:ok, :member}
  defp parse_role(other), do: {:error, {:unknown_role, other}}

  defp email_field(%{"email" => email}) when is_binary(email) do
    # The provider lowercases addresses before its uniqueness check, so match it here
    {:ok, String.downcase(email)}
  end

  defp email_field(_params), do: {:error, {:invalid_field, "email"}}

  defp age_field(%{"age" => text}) when is_binary(text) do
    case Integer.parse(text) do
      {age, ""} -> {:ok, age}
      {_age, _rest} -> {:error, {:invalid_field, "age"}}
      :error -> {:error, {:invalid_field, "age"}}
    end
  end

  defp age_field(_params), do: {:error, {:invalid_field, "age"}}

  defp clamp_adult_age(age) when age < @min_age, do: {:error, :underage}
  defp clamp_adult_age(age), do: {:ok, min(age, @max_age)}

  defp insert_user(attrs) do
    changeset = User.import_changeset(%User{}, attrs)

    case Repo.insert(changeset) do
      {:ok, user} ->
        {:ok, user}

      {:error, %Ecto.Changeset{} = failed} ->
        {:error, insert_error(failed)}
    end
  end

  defp insert_error(changeset) do
    if email_taken?(changeset), do: :email_taken, else: {:invalid_user, changeset}
  end

  defp email_taken?(changeset) do
    case Keyword.get(changeset.errors, :email) do
      {_message, opts} -> opts[:constraint] == :unique
      nil -> false
    end
  end

  defp send_welcome(user) do
    message = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, Mailer, :deliver, [message])
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

## Behavior changes to check

- `return_id` is gone. Callers that used it read `user.id` from the `{:ok, user}` result.
- `notify:` and `silent:` are replaced by `welcome: :email`. Callers that passed `notify: true` must switch to `welcome: :email`.
- Ages above 120 are stored as 120 (finding 4). Before, they were stored unchanged.
- Error reasons changed (finding 6). Callers that matched on `:invalid` or `:insert_failed` must match the new reasons.
- A role not in the list now returns `{:error, {:unknown_role, value}}`. Before, any string became an atom.
- A missing `"role"` or `"age"` key returns an error. Before, it raised.
- The welcome email uses `nickname` (finding 12). Before, it used `name`, which the struct never has, so the greeting was always "Hi there" when it did not crash.

## Assumptions

- `User.import_changeset/2` exists. It casts the four fields, validates them, and calls `unique_constraint(:email)`. The `User` module was not provided, so this is a required change to that module.
- The `users` table has a unique index on `email`. Without it, `unique_constraint/3` does not stop duplicates.
- `Accounts.TaskSupervisor` is started in the application's supervision tree, as `{Task.Supervisor, name: Accounts.TaskSupervisor}`.
- The three roles in `parse_role/1` are placeholders for the roles the application defines.
