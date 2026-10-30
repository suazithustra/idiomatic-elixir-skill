# Review: `Accounts.UserImporter`

Input: `code-review-input.ex`. Rules are from `idiomatic-elixir` (`SKILL.md`, `references/processes.md`, `references/ecto-phoenix.md`).

## Findings

1. **The welcome email always fails.** `welcome_email/1` reads `user[:name]`, but `%User{}` is a struct, and structs do not implement `Access`, so this raises `UndefinedFunctionError` inside the spawned process. Rule: *Read required keys with `map.key` or a pattern*. Line 53: `name = user[:name] || "there"`. Fix: read the nickname the importer already stores, `user.nickname`.

2. **The age cap never applies.** The `if` rebinds `age`, but the new value stays inside the block, so an age of 150 is saved as 150. Rule: *Assign the result of `if`, `case`, and `Enum` calls*. Lines 15-17: `if age > 120 do age = 120 end`. Fix: `age = min(age, 120)`, or `Changeset.update_change/3` as in the improved code.

3. **Every error is swallowed.** `rescue _ -> {:error, :invalid}` wraps the whole function, so a bug in the code (for example, a typo that raises `UndefinedFunctionError`) is reported to the caller as bad input. Rule: *Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs*. Lines 42-43. Fix: remove the `try`. Validate the input and return specific reasons; let real bugs raise.

4. **`String.to_integer/1` raises on bad input inside a `try` used as a tuple converter.** Rule: *Do not wrap a raising call in `try/rescue` to get a tuple*. Line 13: `age = String.to_integer(params["age"])`. Fix: let `cast/3` in a changeset parse the age and report it as invalid.

5. **Atoms are created from external input.** `String.to_atom/1` on the role lets any caller grow the atom table until the node crashes. Rule: *Convert external strings to atoms with explicit clauses*. Line 8: `role = String.to_atom(params["role"])`. Fix: list the accepted roles in `parse_role/1` clauses. The list in the improved code (`"admin"`, `"member"`) is a placeholder; replace it with the real set.

6. **The user is inserted without validation, and uniqueness is checked by hand.** `%User{...}` goes straight to `Repo.insert/1`, so nothing is validated, and the duplicate email check on line 24 runs before the insert, which lets two imports of one address both pass the check. Rule: *Validate input with changesets*, which names `unique_constraint/3` for the duplicate check. Lines 22-25. Fix: build a changeset with `cast/3`, `validate_required/2`, and `validate_number/3`, add `unique_constraint(:email)`, and insert it. The database needs a unique index on `email` for the constraint to fire.

7. **The `return_id` option changes the return shape.** With `return_id: true`, success returns a bare integer, and otherwise it returns `{:ok, user}`. Rule: *Give each function one return shape*. Line 31: `if opts[:return_id], do: user.id, else: {:ok, user}`. Fix: always return `{:ok, user}`; callers that need the ID read `user.id`.

8. **Two booleans overlap.** `notify` and `silent` together have one meaning that `silent` overrides, and `notify: true, silent: true` is a contradiction that the code accepts. Rule: *Use one atom-valued field or option instead of overlapping booleans*. Line 27: `if opts[:notify] && !opts[:silent] do`. Fix: keep `notify` and drop `silent`. Options are also checked now with `Keyword.validate!/2`, so an unknown key such as `silent:` raises at the call site.

9. **A catch-all clause hides the insert error.** `_ -> {:error, :insert_failed}` drops the changeset that explains why the insert failed. Rule: *Match every expected shape and let unexpected ones crash*. Lines 33-34. Fix: return the changeset from the `Repo.insert/1` failure, as the `with` in the improved code does.

10. **The welcome email runs in a bare, unsupervised process.** `spawn/1` is not supervised, so a crash is lost and the process is not visible to monitoring tools. The closure also captures the whole `user`. Rule: *Supervise every long-lived process* and *Send processes only the data they need*. Line 49: `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`. Fix: build the text first, then start it with `Task.Supervisor.start_child/2`. This needs `Accounts.TaskSupervisor` in the application's supervision tree.

11. **The pipe goes into an anonymous function.** The extra sentence is added with a `fn` call inside a pipe. Rule: *Write pipelines that start with a value* (no pipes into anonymous functions). Line 55: `greeting |> (fn text -> text <> " Enjoy your account." end).()`. Fix: put the whole sentence in one string.

12. **A single-step pipe.** Rule: *Do not pipe a single step*. Line 12: `email = params["email"] |> String.downcase()`. Fix: `String.downcase(params["email"])`, or the changeset step in finding 6.

13. **Boolean operators on booleans use `&&`.** `and` checks that both sides are booleans, and `&&` does not. Rule: *Use `and`, `or`, `not` when the operands are booleans*. Line 21: `if is_binary(email) && age >= 18 do`. Fix: the changeset validations in finding 6 replace this check, so the line is removed.

14. **The function nests four levels deep.** Each inner `if` and `case` belongs in its own named function. Rule: *Keep functions short and at one level of detail*. Lines 10-44. Fix: split into `parse_role/1`, `user_changeset/2`, and `send_welcome/1`, as in the improved code.

15. **Documentation sits in plain comments.** The module description and the function description are comments, not `@moduledoc` and `@doc`, so the options are not documented. Rule: *Comments explain why; documentation goes in `@moduledoc` and `@doc`*. Lines 2 and 5. Fix: move them to `@moduledoc` and `@doc`, with `## Options` for `:notify`.

16. **Comments restate the code.** Rule: *Delete comments that restate the code*. Lines 7 (`# Get the role from params`) and 48 (`# send the email`). Fix: delete them. Line 11 explains a reason and stays.

## Improved version

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from external CSV (comma-separated values) or JSON (JavaScript Object Notation) sources.
  """

  alias Accounts.{Repo, User}
  alias Ecto.Changeset

  @min_age 18
  @max_age 120

  @doc """
  Imports one user from string-keyed `params`.

  Returns `{:ok, user}` or `{:error, reason}`. The reason is `{:unknown_role, role}`
  for an unrecognized role, or an `Ecto.Changeset` that lists the invalid fields.
  Ages above 120 are stored as 120.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, role} <- parse_role(params["role"]),
         {:ok, user} <- Repo.insert(user_changeset(params, role)) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("member"), do: {:ok, :member}
  defp parse_role(other), do: {:error, {:unknown_role, other}}

  defp user_changeset(params, role) do
    %User{}
    |> Changeset.cast(params, [:email, :age, :nickname])
    |> Changeset.put_change(:role, role)
    # The provider lowercases addresses before its uniqueness check, so match it here
    |> Changeset.update_change(:email, &String.downcase/1)
    |> Changeset.update_change(:age, &min(&1, @max_age))
    |> Changeset.validate_required([:email, :age])
    |> Changeset.validate_number(:age, greater_than_or_equal_to: @min_age)
    |> Changeset.unique_constraint(:email)
    |> default_nickname()
  end

  defp default_nickname(changeset) do
    nickname =
      Changeset.get_field(changeset, :nickname) || Changeset.get_field(changeset, :email)

    Changeset.put_change(changeset, :nickname, nickname)
  end

  defp send_welcome(user) do
    text = welcome_text(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(text) end)
  end

  defp welcome_text(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

## Changes and open points

- The role list (`"admin"`, `"member"`) is a placeholder. Replace it with the roles the system accepts.
- `User` must have `role`, `nickname`, `email`, and `age` fields. The `role` field can be an `Ecto.Enum` with the same values.
- A unique index on `users.email` is needed for `unique_constraint/3` to catch duplicates.
- `Accounts.TaskSupervisor` must be started in the application's supervision tree.
- Behavior changes for callers: `return_id` and `silent` are removed, and unknown options now raise. The welcome text uses `nickname`, which defaults to the email, so the old "there" fallback is gone.
- The improved code parses, but it is not compiled against the project. The `Repo`, `User`, and `Mailer` modules are not in the input.
