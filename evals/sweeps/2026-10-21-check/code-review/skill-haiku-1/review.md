# Review: `Accounts.UserImporter`

Rules are from `SKILL.md` and the reference files `references/processes.md` and `references/ecto-phoenix.md` (the code uses `Repo` and `spawn`, so both were required).

## Findings

1. **The age cap never applies.** Line 15 `if age > 120 do age = 120 end` rebinds `age` inside the `if`, so the outer `age` stays unchanged and users over 120 are stored as given. Rule: "Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it". Fix: `age = min(age, @max_age)`.

2. **Welcome emails never send.** Line 49 `name = user[:name] || "there"` raises `UndefinedFunctionError`, because structs do not implement `Access` and `User` has no `name` field (the import sets `nickname`). The error happens inside the `spawn` on line 45, so nothing is logged and no email goes out. Rule: "Read required keys with `map.key` or a pattern; keep `map[:key]` for optional keys". Fix: read `user.nickname`, which is never `nil` here because it falls back to the email.

3. **Input creates atoms.** Line 8 `role = String.to_atom(params["role"])` lets any caller grow the atom table, and it raises on a missing role because it runs outside the `try`. Rule: "Convert external strings to atoms with explicit clauses". Fix: one `parse_role/1` clause per accepted value, with an error clause for the rest.

4. **A catch-all `rescue` hides bugs.** Lines 38-40 `rescue _ -> {:error, :invalid}` turn every exception in the function, including a bug in `Repo.insert` or `send_welcome`, into `:invalid`. Rule: "Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs". Fix: parse and validate in functions that return tuples, and remove the `try`.

5. **`String.to_integer/1` raises on bad input.** Line 13 `age = String.to_integer(params["age"])` raises on `"abc"` and on a missing key. Rule: "Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs", which says to call the non-raising version such as `Integer.parse/1`. Fix: `Integer.parse/1` with `{age, ""}` as the only success pattern.

6. **The `_` clause discards the insert error.** Line 32 `_ -> {:error, :insert_failed}` throws away the `{:error, changeset}` that `Repo.insert/1` returns, so the caller cannot see why the insert failed. Rule: "Match every expected shape and let unexpected ones crash". Fix: return the result of `Repo.insert/1` unchanged.

7. **The user is inserted without validation.** Lines 22-24 build `%User{email: email, age: age, role: role, nickname: nickname}` and pass it to `Repo.insert(user)`. Ecto writes the struct as given, so no validation runs and a duplicate email raises. Rule: "Validate input with changesets" (`references/ecto-phoenix.md`). Fix: `%User{} |> User.changeset(attrs) |> Repo.insert()`, with `unique_constraint(:email)` in the changeset.

8. **A pipe feeds an anonymous function.** Line 51 `greeting |> (fn text -> text <> " Enjoy your account." end).()` is hard to read and is named as a pattern to avoid. Rule: "Write pipelines that start with a value and read top to bottom". Fix: an interpolated string, `"Hi #{user.nickname}, welcome! Enjoy your account."`.

9. **A single-step pipe.** Line 12 `email = params["email"] |> String.downcase()` pipes one step. Rule: "Write pipelines that start with a value and read top to bottom", which says to write `String.trim(name)` and not `name |> String.trim()`. Fix: `String.downcase(params["email"])`, inside a function that checks the input is a binary first.

10. **`&&` and `!` are used on booleans.** Line 21 `if is_binary(email) && age >= 18 do` and line 26 `if opts[:notify] && !opts[:silent] do`. Rule: "Use `and`, `or`, `not` when the operands are booleans". Fix: `and` and `not`, or, after the rewrite, a `with` over separate parse steps that makes the operator unnecessary.

11. **An option changes the return shape.** Line 30 `if opts[:return_id], do: user.id, else: {:ok, user}` returns an integer in one mode and a tuple in the other. Rule: "Give each function one return shape". Fix: always return `{:ok, user}`; callers that need the ID read `user.id`.

12. **Two overlapping options.** Line 26 reads `:notify` and `:silent`, and `:silent` overrides `:notify`, so `notify: true, silent: true` makes no sense. Rule: "Use one atom-valued field or option instead of overlapping booleans". Fix: keep only `:notify`. It now holds one yes/no state, so a boolean is enough. Callers that pass `silent: true` need to change.

13. **Options are not validated.** Line 6 `def import_user(params, opts \\ []) do` accepts any keyword, so a misspelled option is ignored. Rule: "Group related parameters", which says to check options with `Keyword.validate!/2`. Fix: `opts = Keyword.validate!(opts, notify: false)`.

14. **A bare `spawn` runs the email send.** Line 45 `spawn(fn -> Mailer.deliver(welcome_email(user)) end)` starts a process outside any supervisor, so a crash is not reported and the process is not tracked. Rule: "Supervise every long-lived process". Fix: `Task.Supervisor.start_child/2`. The closure also captures `user` and builds the email inside the new process; build the email first so the closure captures only the text. Rule: "Send processes only the data they need".

15. **Magic numbers.** Lines 15 (`120`) and 21 (`18`) use bare numbers whose meaning the reader must guess. Rule: "Name magic numbers with module attributes". Fix: `@min_age 18` and `@max_age 120`.

16. **Comments restate the code.** Line 2 (module summary), line 5 (function summary), line 7 (`# Get the role from params`), and line 44 (`# send the email`) repeat what the code shows. Rule: "Comments explain why; documentation goes in `@moduledoc` and `@doc`", which says to "Delete comments that restate the code". Fix: move the module summary to `@moduledoc` and the function summary to `@doc`, and delete the other two. Keep the comment on line 11, which gives the reason for the lowercase step.

17. **One function does four jobs.** Lines 6-41 parse, validate, insert, notify, and return, with nested `if` and `case` blocks. Rule: "Keep functions short and at one level of detail". Fix: a public `import_user/2` that calls `parse_params/1`, `insert_user/1`, and `send_welcome/1`.

## Behavior changes

- `:return_id` and `:silent` are removed. Calls that pass them now raise from `Keyword.validate!/2`.
- A missing or unknown `role` returns `{:error, {:unknown_role, role}}` instead of raising.
- Ages over 120 are now stored as 120.
- The role list (`"admin"`, `"member"`) is a placeholder. Replace it with the roles the `User` schema accepts.
- `User.changeset/2` with `unique_constraint(:email)` and `Accounts.TaskSupervisor` are assumed to exist, as is `Mailer.deliver/1`. The code needs them to compile.
- The `## Examples` section is not added because the function writes to the database and cannot run as a doctest.

## Improved version

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV (comma-separated values) or JSON (JavaScript Object Notation) source.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from string-keyed params.

  Returns `{:ok, user}` or `{:error, reason}`. Ages above 120 are stored as 120.
  Users under 18 are rejected.

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
    with {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         {:ok, role} <- parse_role(params["role"]) do
      {:ok, %{email: email, age: age, role: role, nickname: params["nickname"] || email}}
    end
  end

  defp parse_email(email) when is_binary(email), do: {:ok, String.downcase(email)}
  defp parse_email(_email), do: {:error, :invalid}

  defp parse_age(value) when is_binary(value) do
    case Integer.parse(value) do
      {age, ""} when age >= @min_age -> {:ok, min(age, @max_age)}
      _ -> {:error, :invalid}
    end
  end

  defp parse_age(_value), do: {:error, :invalid}

  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("member"), do: {:ok, :member}
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
