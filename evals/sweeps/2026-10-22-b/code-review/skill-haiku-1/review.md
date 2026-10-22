# Review: `Accounts.UserImporter`

Rules are from `idiomatic-elixir/SKILL.md`, plus `references/processes.md` (for `spawn`) and `references/ecto-phoenix.md` (for `Repo.insert` and the struct-based write).

## Findings

1. **Atoms from external input** (Pattern matching: "Convert external strings to atoms with explicit clauses")
   - Line 8: `role = String.to_atom(params["role"])`
   - Fails: the atom table grows with every distinct role string from the import file, and a `nil` role raises `ArgumentError` outside the `try`.
   - Fix: declare `role` as an `Ecto.Enum` on `User` and let `cast/3` convert the string. Unknown values become changeset errors.

2. **Blanket `rescue` hides bugs** (Control flow: "Return `{:ok, value}` or `{:error, reason}`...; raise only for bugs")
   - Lines 10, 38-40: `try do ... rescue _ -> {:error, :invalid} end`
   - Fails: any bug in the body, such as a typo or a broken `Repo` call, is reported as "invalid data".
   - Fix: remove the `try`. Use non-raising calls and the changeset.

3. **Raising parse on external input** (Control flow: "Return `{:ok, value}` ... for expected failures")
   - Line 13: `age = String.to_integer(params["age"])`
   - Fails: a blank or non-numeric age crashes the `try` and returns `{:error, :invalid}` without saying which field failed.
   - Fix: `Integer.parse/1` in `parse_age/1`, returning `{:error, {:invalid_field, "age"}}` or `{:error, {:missing_field, "age"}}`.

4. **Rebinding inside `if` does not escape** (Assign the result of `if`...)
   - Lines 15-17: `if age > 120 do age = 120 end`
   - Fails: `age` stays unchanged after the block, so ages above 120 are stored unclamped. This is a correctness bug, not only style.
   - Fix: `min(age, @max_age)` in `parse_age/1`.

5. **Pipe with a single step, crashes on `nil`** (Pipelines: "Do not pipe a single step")
   - Line 12: `email = params["email"] |> String.downcase()`
   - Fails: `String.downcase(nil)` raises when the email is missing.
   - Fix: `normalize_email/1` with a binary clause and a fallback clause, and a plain function call.

6. **`&&` on booleans** (Use `and`, `or`, `not` when the operands are booleans)
   - Line 21: `if is_binary(email) && age >= 18 do`
   - Fix: the check moves into `User.changeset/2` (`validate_number`). The importer no longer builds the boolean.

7. **Struct written without a changeset** (Ecto: "Validate input with changesets")
   - Lines 22-24: `user = %User{email: email, age: age, role: role, nickname: nickname}` then `Repo.insert(user)`
   - Fails: nothing is validated, and a uniqueness violation raises instead of returning `{:error, changeset}`.
   - Fix: `%User{} |> User.changeset(attrs) |> Repo.insert()`.

8. **Catch-all error clause loses the reason** (Pattern matching: "Match every expected shape")
   - Lines 32-33: `_ -> {:error, :insert_failed}`
   - Fails: the changeset that explains the failure is discarded, and any future return value is mapped to the same error.
   - Fix: `{:error, changeset}` is returned as is, through `with`.

9. **Overlapping booleans** (Modeling: "Use one atom-valued field or option instead of overlapping booleans")
   - Line 26: `if opts[:notify] && !opts[:silent] do`
   - Fails: `notify: true, silent: true` is a meaningless combination. `silent` only cancels `notify`.
   - Fix: a single `notify:` option taking `:welcome` or `:none`. `:silent` is removed. **API change:** callers that pass `silent:` now get an error from `Keyword.validate!/2`.

10. **Options unchecked** (Group related parameters: "check them with `Keyword.validate!/2`")
    - Line 6: `def import_user(params, opts \\ [])` with no validation of `opts`.
    - Fails: a misspelled option (`notfy: true`) is silently ignored.
    - Fix: `Keyword.validate!(opts, notify: :none)`.

11. **Options change the return shape** (Modeling: "Give each function one return shape")
    - Line 30: `if opts[:return_id], do: user.id, else: {:ok, user}`
    - Fails: callers get an integer or a tuple depending on an option.
    - Fix: remove `:return_id`. The caller reads `user.id` from `{:ok, user}`. **API change.**

12. **Unsupervised process** (Processes: "Supervise every long-lived process"; "Fire-and-forget work" uses `Task.Supervisor.start_child/2`)
    - Line 45: `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`
    - Fails: a crashed send is lost silently, and the process is invisible to supervision and LiveDashboard.
    - Fix: `Task.Supervisor.start_child(Accounts.TaskSupervisor, ...)`. The app must start `{Task.Supervisor, name: Accounts.TaskSupervisor}`.

13. **Struct accessed with `Access`** (Pattern matching: "Read required keys with `map.key`...")
    - Line 49: `name = user[:name] || "there"`
    - Fails: `User` is a struct, so `user[:name]` raises `UndefinedFunctionError`. The welcome email has never worked.
    - Fix: `user.nickname`. `nickname` is always set, because it falls back to the email.

14. **Pipe into an anonymous function** (Pipelines: "Do not pipe into an anonymous function call")
    - Line 51: `greeting |> (fn text -> text <> " Enjoy your account." end).()`
    - Fix: one interpolated string.

15. **String concatenation for a template** (Readability; interpolation)
    - Line 50: `greeting = "Hi " <> name <> ", welcome!"`
    - Fix: `"Hi #{user.nickname}, welcome! Enjoy your account."` in `welcome_email/1`.

16. **Nested control flow in one function** (Readability: "Keep functions short and at one level of detail")
    - Lines 15-37: `if` inside `try` inside `if` inside `case` inside `if`
    - Fix: a `with` over two steps (`parse_age/1`, `insert_user/2`), with the details in private functions.

17. **Magic numbers** (Readability: "Name magic numbers with module attributes")
    - Line 15: `120`. Line 21: `18`.
    - Fix: `@max_age 120` in the importer. The minimum age moves into `User.changeset/2` as `@min_age 18`.

18. **Comments that restate code or belong in docs** (Readability: "Comments explain why; documentation goes in `@moduledoc` and `@doc`")
    - Line 2: module description, should be `@moduledoc`.
    - Line 5: `# Import a single user from the given params`, should be `@doc`.
    - Lines 7, 44: `# Get the role from params`, `# send the email`. Delete.
    - Line 11: `# The provider lowercases addresses...` explains a reason. Keep it.

19. **Option not documented** (Readability: `@doc` with `## Options`)
    - Fix: `@doc` with `## Options` for `:notify`.

## Assumptions the improved code relies on

- `Accounts.User` has `Ecto.Enum` `role`, `email`, `age`, `nickname` fields, and `User.changeset/2` casts them, requires `email` and `role`, applies `validate_number(:age, greater_than_or_equal_to: 18)` (with `@min_age 18`), and calls `unique_constraint(:email)`.
- `Accounts.TaskSupervisor` is started in the application's supervision tree.
- `Mailer.deliver/1` is unchanged.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.{Repo, User}

  @max_age 120

  @doc """
  Imports one user from `params` and returns `{:ok, user}` or `{:error, reason}`.

  Ages above 120 are stored as 120. Invalid attributes, such as an age under 18
  or an unknown role, return `{:error, changeset}`.

  ## Options

    * `:notify` - `:welcome` sends a welcome email after the insert. Defaults to `:none`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: :none)

    with {:ok, age} <- parse_age(params["age"]),
         {:ok, user} <- insert_user(params, age) do
      notify(user, opts[:notify])
      {:ok, user}
    end
  end

  defp insert_user(params, age) do
    email = normalize_email(params["email"])

    attrs = %{
      email: email,
      age: age,
      role: params["role"],
      nickname: params["nickname"] || email
    }

    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp parse_age(age) when is_integer(age), do: {:ok, min(age, @max_age)}

  defp parse_age(text) when is_binary(text) do
    case Integer.parse(text) do
      {age, ""} -> {:ok, min(age, @max_age)}
      _ -> {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(_missing), do: {:error, {:missing_field, "age"}}

  # The provider lowercases addresses before its uniqueness check, so match it here
  defp normalize_email(email) when is_binary(email), do: String.downcase(email)
  defp normalize_email(email), do: email

  defp notify(user, :welcome), do: send_welcome(user)
  defp notify(_user, :none), do: :ok

  defp send_welcome(user) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

## Behavior changes to confirm

- `:silent` and `:return_id` options are removed (findings 9 and 11). Callers must update.
- Errors are now `{:error, changeset}` or `{:error, {:invalid_field, "age"}}` instead of `{:error, :invalid}` and `{:error, :insert_failed}`. Callers that match on the old atoms must be updated.
- The welcome email now greets by nickname. Before, it raised on every call, so it never sent.
