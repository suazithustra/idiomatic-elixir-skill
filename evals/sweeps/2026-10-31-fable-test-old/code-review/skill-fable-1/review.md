# Review of `Accounts.UserImporter`

The module parses untrusted input by hand, hides every failure behind one `:invalid` error, and has two outright bugs: the age cap never applies, and the welcome email crashes when it reads the user. The fix is to parse the role with explicit clauses, validate the rest through an `Ecto.Changeset`, chain the two fallible steps with `with`, and send the email from a supervised task.

References read for this review: `SKILL.md`, `references/processes.md` (for `spawn`), `references/ecto-phoenix.md` (for `Repo`).

## Findings

1. **Comments explain why; documentation goes in `@moduledoc` and `@doc`.** Lines 2, 5, 7 and 48 (`# This module imports users from an external CSV/JSON source`, `# Import a single user from the given params`, `# Get the role from params`, `# send the email`) restate the code or document the public API in comments. Fix: a `@moduledoc`, a `@doc` on `import_user/2` with an `## Options` section, and delete the other three. The line 11 comment about the provider lowercasing addresses explains a reason the code cannot show, so it stays.

2. **Convert external strings to atoms with explicit clauses.** Line 8, `role = String.to_atom(params["role"])`, lets whoever controls the input create unbounded atoms until the VM (virtual machine) hits its atom limit and crashes. It also raises on a missing role, and it sits outside the `try`, so that raise escapes. Fix: a `parse_role/1` with one clause per accepted role, a clause for `nil` returning `{:error, {:missing_field, "role"}}`, and a final clause returning `{:error, {:unknown_role, other}}`. The accepted roles below are placeholders; take the real list from the `User` schema, or switch the field to `Ecto.Enum` and let `cast/3` do it.

3. **Return tuples for expected failures; raise only for bugs; never `rescue _ ->`.** Lines 10 and 42 to 43, `try do ... rescue _ -> {:error, :invalid} end`, wrap the whole function to turn `String.to_integer/1` and anything else that raises, including bugs, into the same `:invalid`. Fix: drop the `try`; `cast/3` parses `"age"` into an integer and reports a bad value in the changeset.

4. **Assign the result of `if`; rebinding inside a block does not escape it.** Lines 15 to 17, `if age > 120 do age = 120 end`, never change `age`, so the cap is dead code and the compiler warns. Fix: `update_change(:age, &min(&1, @max_age))` on the changeset, with the limit named as a module attribute (`@max_age 120`) under the magic-numbers rule.

5. **Do not pipe a single step.** Line 12, `email = params["email"] |> String.downcase()`, pipes one call. Fix: `String.downcase(params["email"])`. In the improved version this becomes `update_change(:email, &String.downcase/1)` so the normalisation applies to the cast value and a missing email is reported by `validate_required/2` instead of raising.

6. **Use `and`, `or`, `not` when the operands are booleans.** Line 21, `if is_binary(email) && age >= 18 do`, uses `&&` on two booleans. Fix: `and`. In the improved version the check itself moves into the changeset as `validate_required([:email, :age])` and `validate_number(:age, greater_than_or_equal_to: @min_age)`, so each failure names its field instead of collapsing to `:invalid`.

7. **Validate input with changesets.** Line 22, `user = %User{email: email, age: age, role: role, nickname: nickname}`, followed by `Repo.insert(user)` on line 25, inserts a struct built straight from the params, so Ecto validates nothing and a constraint violation raises. Fix: `%User{role: role} |> cast(params, [:email, :age, :nickname]) |> ... |> Repo.insert()`. The role is set on the struct before `cast/3` because the code, not the request, decides its value after parsing.

8. **Declare database constraints in the changeset instead of a lookup before an insert.** Line 24, `if Repo.get_by(User, email: email) == nil do`, is a read-then-write race: two concurrent imports of the same address both pass the check, and the second insert raises. Fix: `unique_constraint(:email)` on the changeset, so a duplicate returns `{:error, changeset}`.

9. **Match every expected shape and let unexpected ones crash.** Lines 33 to 34, `_ -> {:error, :insert_failed}`, turn `{:error, changeset}` and anything else into an atom the caller cannot act on. Fix: let `with` pass `{:error, changeset}` through unchanged, which also removes the `case`.

10. **Use one atom-valued field or option instead of overlapping booleans.** Line 27, `if opts[:notify] && !opts[:silent] do`, has two options where one overrides the other, and `notify: true, silent: true` makes no sense. Fix: keep `:notify` only, and check the options with `Keyword.validate!(opts, notify: false)` so a misspelled option raises at the call site.

11. **Give each function one return shape.** Line 31, `if opts[:return_id], do: user.id, else: {:ok, user}`, makes the return type depend on an option. Fix: always return `{:ok, user}`; a caller that wants the id reads `user.id`.

12. **Keep functions short and at one level of detail; chain fallible steps with `with`.** Lines 10 to 44 nest `try`, `if`, `if`, `case` and `if` five levels deep. Fix: `import_user/2` becomes a two-step `with` (`parse_role/1`, then `Repo.insert/1`), with the changeset built in a private `import_changeset/2` and the nickname default in `put_default_nickname/1`.

13. **Supervise every long-lived process.** Line 49, `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`, starts a process no supervisor knows about: it is invisible to shutdown, restarts and Observer, and a crash is silent. Fix: `Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)`, with `{Task.Supervisor, name: Accounts.TaskSupervisor}` added to the application's supervision tree.

14. **Send processes only the data they need.** The same line 49 captures the whole `user` struct in the closure, so the spawned process copies all of it. Fix: build the email first, `email = welcome_email(user)`, and capture only `email`.

15. **Read struct fields with `user.name`, not `user[:name]`.** Line 53, `name = user[:name] || "there"`, calls `Access` on a struct, which raises `UndefinedFunctionError` every time, so the welcome email never sends. The struct is built with `nickname`, not `name`, and the nickname always falls back to the email, so the `"there"` default is dead too. Fix: `user.nickname`.

16. **Do not pipe into an anonymous function call.** Line 55, `greeting |> (fn text -> text <> " Enjoy your account." end).()`, wraps a string concatenation in a lambda just to pipe into it. Fix: one interpolated string, `"Hi #{user.nickname}, welcome! Enjoy your account."`.

17. **Open a module with `use`, `import`, `alias`, `require`, in that order.** The improved version adds `import Ecto.Changeset` and places it above the existing `alias`, with a blank line between the groups.

Not changed: the `Mailer` module is neither aliased nor namespaced, and `Accounts` may itself be the top-level application. Both are outside what this file shows, so I left them.

## Improved version

Checked with `mix format --check-formatted` (no changes) and parsed with `Code.string_to_quoted!/1`. A full compile needs Ecto and the `User` schema, which are not available outside the Mix project.

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  import Ecto.Changeset

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from string-keyed `params`.

  Returns `{:ok, user}`, `{:error, changeset}` when a field is missing or
  invalid, or `{:error, {:unknown_role, value}}` for a role the import does
  not accept.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, role} <- parse_role(params["role"]),
         {:ok, user} <- Repo.insert(import_changeset(params, role)) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("editor"), do: {:ok, :editor}
  defp parse_role("member"), do: {:ok, :member}
  defp parse_role(nil), do: {:error, {:missing_field, "role"}}
  defp parse_role(other), do: {:error, {:unknown_role, other}}

  defp import_changeset(params, role) do
    %User{role: role}
    |> cast(params, [:email, :age, :nickname])
    |> validate_required([:email, :age])
    # The provider lowercases addresses before its uniqueness check, so match it here
    |> update_change(:email, &String.downcase/1)
    |> update_change(:age, &min(&1, @max_age))
    |> validate_number(:age, greater_than_or_equal_to: @min_age)
    |> unique_constraint(:email)
    |> put_default_nickname()
  end

  defp put_default_nickname(changeset) do
    case get_field(changeset, :nickname) do
      nil -> put_change(changeset, :nickname, get_field(changeset, :email))
      _nickname -> changeset
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

Assumptions in the improved version: the `User` schema has `email`, `age`, `role` and `nickname` fields; the accepted roles are `admin`, `editor` and `member`; a `Task.Supervisor` named `Accounts.TaskSupervisor` is in the supervision tree; and `Mailer.deliver/1` accepts the string the original passed it.
