# Review: `Accounts.UserImporter`

Rule names below are headings from the idiomatic-elixir skill: `SKILL.md`, `references/ecto-phoenix.md`, and `references/processes.md`. Both the original and the improved module were compiled and run against stub `Repo`, `User`, and `Mailer` modules. The findings below are the ones that run confirmed.

## Findings

1. The age clamp never runs. `if age > 120 do` / `age = 120` (lines 15-17) rebinds `age` inside an `if`, and the new value does not leave the block (`SKILL.md`, "Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it"). In the run, age `"150"` was stored as `150`. Fix: `min(age, @max_age)` in `parse_age/1`.

2. The role string becomes an atom. `role = String.to_atom(params["role"])` (line 8) turns any input into an atom, and `"root"` was imported as `:root` (`SKILL.md`, "Convert external strings to atoms with explicit clauses"). Fix: `parse_role/1` with one clause per allowed role and `{:error, {:unknown_role, other}}` for the rest.

3. A `rescue _ ->` clause hides failures. `try do` (line 10) and `rescue _ -> {:error, :invalid}` (lines 42-43) wrap the whole function, which `SKILL.md` ("Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs") forbids. It also reports database errors as `:invalid`. Line 8 sits outside the `try`, so a missing role raises `ArgumentError` (confirmed). Fix: remove the `try`; each step returns a tuple.

4. `String.to_integer/1` raises on bad input. `age = String.to_integer(params["age"])` (line 13) raises on `"abc"` (confirmed). The same rule as finding 3 applies: call the non-raising `Integer.parse/1` (`SKILL.md`, "Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs"). Fix: `parse_age/1` matches on `Integer.parse/1`'s result.

5. The params are read without checking their shape. `params["email"]` and `params["age"]` (lines 12-13, 19) pass through whatever they hold, and a missing key reaches a function that cannot handle it. Fix: `parse_params/1` matches `"email"`, `"age"`, and `"role"` in its head, with `defp parse_params(_params), do: {:error, :invalid_payload}` below it (`SKILL.md`, "Parse external data into structs where it enters the system": "Match the required keys of string-keyed input in a function head or `case`").

6. A single-step pipe. `params["email"] |> String.downcase()` (line 12) pipes one call. Fix: `String.downcase(email)` inside `parse_email/1` (`SKILL.md`, "Write pipelines that start with a value and read top to bottom": "Do not pipe a single step").

7. Every failure returns the same reason. `{:error, :invalid}` (lines 37 and 40) covers a duplicate email, an underage user, and a bad field alike, so a caller cannot tell them apart (`SKILL.md`, "Match every expected shape and let unexpected ones crash": "Different failures need different reasons too"). Fix: `{:error, :underage}`, `{:error, {:invalid_field, "age"}}`, `{:error, {:unknown_role, role}}`, and the changeset for a duplicate.

8. A lookup runs before the insert, and the struct is inserted raw. `if Repo.get_by(User, email: email) == nil do` (line 24) is followed by `Repo.insert(user)` on a `%User{}` built by hand (lines 22 and 25). Two imports of one email can both pass the lookup, and nothing is validated (`references/ecto-phoenix.md`, "Validate input with changesets": declare `unique_constraint/3`). Fix: `User.changeset/2` declares `unique_constraint(:email)`, and `insert_user/1` pipes the struct through it. A duplicate then returns `{:error, changeset}`.

9. A catch-all clause swallows the insert result. `_ -> {:error, :insert_failed}` (line 33) turns every other return value into one error (`SKILL.md`, "Match every expected shape and let unexpected ones crash"). Fix: `insert_user/1` returns the `Repo.insert/1` result unchanged, so the changeset error reaches the caller.

10. One function returns two shapes. `if opts[:return_id], do: user.id, else: {:ok, user}` (line 31) returns an integer in one mode and a tuple in the other (`SKILL.md`, "Give each function one return shape"). Fix: remove `:return_id`. Callers read `user.id` from `{:ok, user}`. Any caller that passes `return_id: true` will break.

11. Two booleans overlap. `opts[:notify] && !opts[:silent]` (line 27) gives no sensible result for `notify: true, silent: true` (`SKILL.md`, "Use one atom-valued field or option instead of overlapping booleans"). Fix: drop `:silent`, so `notify: true` sends the welcome email.

12. The options and the function are documented with comments, and options are not validated. Lines 2 and 5 hold the documentation as plain comments, and an unknown option is ignored without a message. Fix: `@moduledoc` and `@doc` with a `## Options` section, and `Keyword.validate!(opts, notify: false)` (`SKILL.md`, "Comments explain why; documentation goes in `@moduledoc` and `@doc`" and "Group related parameters").

13. The function is too long and nests too deeply. `import_user/2` holds a `try`, three `if`s, and a `case` inside each other (lines 10-44). Fix: split it into `parse_params/1`, `check_age/1`, and `insert_user/1`, and chain them with `with` (`SKILL.md`, "Keep functions short and at one level of detail" and "Chain fallible steps with `with`; normalize each step's error in a small private function").

14. `&&` joins two booleans, and one check is dead code. `if is_binary(email) && age >= 18 do` (line 21) joins two boolean values, so `and` fits (`SKILL.md`, "Use `and`, `or`, `not` when the operands are booleans"). The `is_binary(email)` check never matters, because line 12 already called `String.downcase/1` on the email. Fix: `parse_email/1` checks the type, and `check_age/1` checks the age.

15. The welcome email runs in a bare `spawn`. `spawn(fn -> Mailer.deliver(welcome_email(user)) end)` (line 49) starts a process no supervisor watches (`references/processes.md`, "Supervise every long-lived process"). The closure also copies the whole `user` into that process, and builds the message there (`references/processes.md`, "Send processes only the data they need"). Fix: build the message in the caller and start it with `Task.Supervisor.start_child/2`.

16. The welcome email crashes. `name = user[:name] || "there"` (line 53) raises `UndefinedFunctionError`, because structs do not implement `Access` (`SKILL.md`, "Read required keys with `map.key` or a pattern; keep `map[:key]` for optional keys", which says "Structs do not implement `Access`"). Confirmed. The crash happens in the spawned process, so no email is sent and the error appears only in the logs. This module never sets a `name` field; `nickname` is the one name it stores. Fix: greet with `user.nickname`.

17. The pipe ends in an anonymous function. `greeting |> (fn text -> text <> " Enjoy your account." end).()` (line 55) is the pattern `SKILL.md` names in "Write pipelines that start with a value and read top to bottom": "Do not pipe into an anonymous function call". Fix: one interpolated string in `welcome_message/1`.

18. Comments restate the code. Lines 2, 5, 7, and 48 describe what the next line already shows (`SKILL.md`, "Comments explain why; documentation goes in `@moduledoc` and `@doc`": "Delete comments that restate the code"). Line 11 gives a reason and stays. Fix: delete the four restating comments.

## Improved version

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external source, such as a CSV (comma-separated values)
  or JSON (JavaScript Object Notation) feed.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from string-keyed params.

  Returns `{:ok, user}`, or `{:error, reason}`. A duplicate email returns
  `{:error, changeset}`.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, attrs} <- parse_params(params),
         :ok <- check_age(attrs.age),
         {:ok, user} <- insert_user(attrs) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  defp parse_params(%{"email" => email, "age" => age, "role" => role} = params) do
    with {:ok, email} <- parse_email(email),
         {:ok, age} <- parse_age(age),
         {:ok, role} <- parse_role(role) do
      {:ok, %{email: email, age: age, role: role, nickname: params["nickname"] || email}}
    end
  end

  defp parse_params(_params), do: {:error, :invalid_payload}

  # The provider lowercases addresses before its uniqueness check, so match it here
  defp parse_email(email) when is_binary(email), do: {:ok, String.downcase(email)}
  defp parse_email(_email), do: {:error, {:invalid_field, "email"}}

  defp parse_age(text) when is_binary(text) do
    case Integer.parse(text) do
      {age, ""} -> {:ok, min(age, @max_age)}
      {_age, _rest} -> {:error, {:invalid_field, "age"}}
      :error -> {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(_age), do: {:error, {:invalid_field, "age"}}

  defp check_age(age) when age >= @min_age, do: :ok
  defp check_age(_age), do: {:error, :underage}

  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("editor"), do: {:ok, :editor}
  defp parse_role("member"), do: {:ok, :member}
  defp parse_role(other), do: {:error, {:unknown_role, other}}

  defp insert_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp send_welcome(user) do
    message = welcome_message(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(message) end)
  end

  defp welcome_message(user), do: "Hi #{user.nickname}, welcome! Enjoy your account."
end
```

## Assumptions and behavior changes

- `User.changeset/2` is assumed to cast `:email`, `:age`, `:role`, and `:nickname`, require `:email`, `:age`, and `:role`, and call `unique_constraint(:email)`. The role field is assumed to be `field :role, Ecto.Enum, values: [:admin, :editor, :member]`. The role names are placeholders; replace them with the real list.
- `Accounts.TaskSupervisor` is assumed to be started in the application's supervision tree.
- `Mailer.deliver/1` is assumed to accept the message text, as in the original.
- Behavior changes: `return_id` and `silent` are removed; a duplicate email returns `{:error, changeset}` instead of `{:error, :invalid}`; a missing or non-string field returns `{:error, :invalid_payload}` or `{:error, {:invalid_field, key}}`; the welcome email greets by nickname.
- Verification: both versions were compiled and run against stub modules. The improved module returns the expected result for each case, including the age clamp, the unknown role, and the welcome email.
