# Review: `Accounts.UserImporter`

Rules are from `idiomatic-elixir` (SKILL.md), plus `references/ecto-phoenix.md` (triggered by `Repo`) and `references/processes.md` (triggered by `spawn`).

## Findings

1. **Blanket `rescue` hides every failure (correctness).** Line 42-43: `rescue _ -> {:error, :invalid}`. Rule: "rescue the specific exception, never `rescue _ ->` … around a whole function." A database outage or a bug in `Repo.insert` is reported to the caller as bad input. Fix: remove the `try`; use non-raising calls and changesets so nothing needs rescuing.

2. **Atom created from external input (security).** Line 8: `String.to_atom(params["role"])`. Rule: "`String.to_atom/1` on input lets anyone who controls the input exhaust [the atom table]." It also runs outside the `try`, so a missing `"role"` crashes the caller. Fix: declare `role` as an `Ecto.Enum` field in `User` and cast it in the changeset.

3. **Non-raising calls swallowed by the `rescue` (error handling).** Line 13: `String.to_integer(params["age"])`. Rule: "Call the non-raising version instead." Fix: let `cast/3` convert `"age"` to an integer and report an invalid value as a changeset error.

4. **Single-step pipe, and a crash on missing input (style).** Line 12: `params["email"] |> String.downcase()`. Rule: "Do not pipe a single step." It also raises on a `nil` email before the `is_binary/1` check on line 21 can run. Fix: `normalize_email/1` with a binary guard.

5. **Age clamp never takes effect (bug).** Lines 15-17: `if age > 120 do age = 120 end`. Rule: "rebinding inside a block does not escape it." The outer `age` stays above 120, so it is inserted unclamped. Fix: `Ecto.Changeset.update_change/3` with `min/2`.

6. **Nested `if`/`case` instead of function clauses and a changeset (readability, Ecto).** Lines 15-41 nest four levels. Rule: "Branch with function clauses and guards before reaching for `if` or `cond`"; "Use `and`, `or`, `not` when the operands are booleans" (line 21 uses `&&` on a boolean). Validation belongs in `User.changeset/2`, not in a nest of `if`s.

7. **Manual uniqueness check before insert (correctness, Ecto).** Lines 24-25: `Repo.get_by(User, email: email) == nil` followed by `Repo.insert`. Rule (ecto-phoenix): declare the constraint with `unique_constraint/3` so a violation returns `{:error, changeset}`. The lookup is also a race: two imports of the same email can both pass it.

8. **Struct inserted without a changeset (Ecto).** Line 22 builds `%User{email: ..., role: role, ...}` and line 25 inserts it. Rule (ecto-phoenix): "A `%User{}` built from the params and passed to `Repo.insert/1` is the pattern to replace." Nothing is validated. Fix: `%User{} |> User.changeset(attrs) |> Repo.insert()`.

9. **Catch-all error clause (error handling).** Lines 33-34: `_ -> {:error, :insert_failed}`. Rule: "Match every expected shape." It collapses every failure into one atom and drops the changeset that explains it.

10. **Option changes the return shape (API).** Line 31: `if opts[:return_id], do: user.id, else: {:ok, user}`. Rule: "Give each function one return shape." Callers get an integer or a tuple depending on a flag. Fix: always return `{:ok, user}`; callers read `user.id`.

11. **Overlapping booleans (API).** Line 27: `opts[:notify] && !opts[:silent]`. Rule: "Use one atom-valued field or option instead of overlapping booleans." `notify: true, silent: true` is meaningless. Fix: drop `:silent`, since "silent" is `notify: false`.

12. **Options not validated (API).** Line 6: `opts \\ []` is read with `opts[:key]` and never checked. Rule: "check them with `Keyword.validate!/2`, and document each one under `## Options`." Fix: `Keyword.validate!(opts, notify: false)`.

13. **Unsupervised `spawn` (processes).** Line 49: `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`. Rule (processes.md): "Supervise every long-lived process … A bare `spawn/1` … has none of this." Fix: `Task.Supervisor.start_child/2`. The closure also captures the whole `user`, and `welcome_email/1` runs inside the spawned process; build the email first and pass only that. Rule: "Send processes only the data they need."

14. **Welcome email never sends (bug).** Line 53: `user[:name] || "there"`. Rule: "Structs do not implement `Access`: `user[:name]` raises `UndefinedFunctionError`." The error happens inside the spawned process, so it fails silently. `User` has no `name` field; the field is `nickname`. Fix: `user.nickname`.

15. **Pipe into an anonymous function (readability).** Line 55: `greeting |> (fn text -> text <> " Enjoy your account." end).()`. Rule: "Do not pipe into an anonymous function call." Fix: one interpolated string.

16. **Comments in the wrong place, or restating code (readability).** Line 2 describes the module and should be `@moduledoc`. Line 5 documents a public function and should be `@doc`. Lines 7 (`# Get the role from params`) and 48 (`# send the email`) restate the code. Line 11 (`# The provider lowercases addresses …`) explains a reason and stays, moved to `normalize_email/1`.

## Assumptions about code not in the input

The improved code relies on these being true in the project. If they are not, the changes need adjusting:

- `User.changeset/2` casts `email`, `age`, `role`, `nickname`; validates required fields and `validate_number(:age, greater_than_or_equal_to: 18)`; calls `unique_constraint(:email)`.
- `User.role` is `Ecto.Enum` with the accepted values (the old `String.to_atom` call accepted any string).
- `Accounts.TaskSupervisor` is started in the application supervision tree.
- `Mailer.deliver/1` is unchanged.

## API changes

- Invalid input now returns `{:error, changeset}` instead of `{:error, :invalid}` or `{:error, :insert_failed}`. Callers that match on the atoms must change.
- `:return_id` and `:silent` options are removed. Passing either now raises from `Keyword.validate!/2`.
- The welcome greeting now uses the nickname (previously it never sent because of finding 14).

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.{Repo, User}

  @max_age 120

  @doc """
  Imports a single user from string-keyed params.

  Returns `{:ok, user}`, or `{:error, changeset}` when the params are invalid
  or the email is already taken. Callers that need the new ID read `user.id`.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    changeset =
      %User{}
      |> User.changeset(import_attrs(params))
      |> clamp_age()

    case Repo.insert(changeset) do
      {:ok, user} ->
        if opts[:notify], do: send_welcome(user)
        {:ok, user}

      {:error, _changeset} = error ->
        error
    end
  end

  defp import_attrs(params) do
    email = normalize_email(params["email"])

    params
    |> Map.put("email", email)
    |> Map.put("nickname", params["nickname"] || email)
  end

  # The provider lowercases addresses before its uniqueness check, so match it here
  defp normalize_email(email) when is_binary(email), do: String.downcase(email)
  defp normalize_email(email), do: email

  defp clamp_age(changeset) do
    Ecto.Changeset.update_change(changeset, :age, &min(&1, @max_age))
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
