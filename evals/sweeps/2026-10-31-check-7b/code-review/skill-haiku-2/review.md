# Review: `Accounts.UserImporter`

## Findings

Most severe first. Each finding names the rule from the idiomatic-elixir skill, quotes the line, and says what the improved code does instead.

1. **Age cap never applies.** Ages over 120 are stored unchanged. Rule: "Assign the result of `if`, `case`, and `Enum` calls". Line 16, `age = 120`, sets a variable inside an `if`, and that value stays inside the block. Fix: `update_change(:age, &min(&1, @max_age))` in the changeset.

2. **Blanket rescue hides real failures.** A database outage or a bug returns `{:error, :invalid}`, the same as bad input. Rule: "never `rescue _ ->` around a whole function". Line 43, `_ -> {:error, :invalid}`. Fix: remove the `try`, and let expected failures return tuples.

3. **Atoms created from external input.** `String.to_atom/1` on `params["role"]` lets any caller add atoms to the VM, and a missing role raises before the `try` runs. Rule: "Convert external strings to atoms with explicit clauses". Line 8. Fix: declare `role` as an `Ecto.Enum` field, which casts only the listed values.

4. **Crash on every notified import.** `user[:name]` raises `UndefinedFunctionError` because structs do not implement `Access`. The `User` struct built on line 22 has no `name` field. Rule: "Structs do not implement `Access`", in the "Read required keys" section. Line 53. This runs only when a welcome email is sent. Fix: read `user.nickname`, which always has a value because the nickname defaults to the email.

5. **Expected input errors raise.** `String.to_integer/1` raises on text such as `"abc"`, and the blanket rescue then turns it into `:invalid`. Rule: "Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs". Line 13. Fix: `cast/3` in the changeset returns an error for a non-number.

6. **Validation done by hand.** The code reads `params["email"]`, `params["age"]`, and `params["role"]` one at a time, checks them with `if`, and inserts a bare `%User{}` struct. Rule: "Cast and validate external input with `Ecto.Changeset` instead of checking fields by hand". Lines 9 to 25. Fix: `User.import_changeset/2` casts and validates all fields, and `Repo.insert/1` takes the changeset.

7. **Check, then insert.** Two imports of the same email can both pass `Repo.get_by/2` before either inserts, and the second one then fails with a database error. Rule: declare the constraint in the changeset with `unique_constraint/3`. Line 24. Fix: `unique_constraint(:email)`. The database also needs a unique index on `email`; this is not in the input and must exist for the constraint to work.

8. **Catch-all error clause.** `_ -> {:error, :insert_failed}` hides the reason, including validation errors. Rule: "Match every expected shape and let unexpected ones crash". Lines 33 to 34. Fix: the `with` passes `{:error, changeset}` through unchanged.

9. **Two return shapes from one function.** With `return_id: true`, `import_user/2` returns an integer ID, and otherwise a tuple. Rule: "Give each function one return shape". Line 31. Fix: the option is removed, and callers read `user.id` from `{:ok, user}`. This is a breaking change for callers that pass `return_id: true`.

10. **Overlapping booleans.** `notify` and `silent` both control one email. Rule: "Use one atom-valued field or option instead of overlapping booleans". Line 27. Fix: `silent` is removed, and `notify` defaults to `false`. Callers that passed `silent: true` must now omit `notify`. This is a breaking change for them.

11. **Fire-and-forget process outside a supervisor.** A bare `spawn/1` has no supervisor, so a crash is lost and the process does not show up in tools such as Observer. Rule: "Supervise every long-lived process". Line 49. Fix: `Task.Supervisor.start_child/2`. The application must start `Accounts.TaskSupervisor` in its supervision tree; this is not in the input.

12. **Pipe into an anonymous function.** Rule: "Do not pipe into an anonymous function call". Line 55, `greeting |> (fn text -> ... end).()`. Fix: a string interpolation.

13. **`&&` on booleans.** Rule: "Use `and`, `or`, `not` when the operands are booleans". Line 21, `is_binary(email) && age >= 18`. Fix: the check moves into the changeset, so the operator goes away. The rule still applies to any boolean check left in the code.

14. **Magic numbers.** Rule: "Name magic numbers with module attributes". Lines 15 and 21, `120` and `18`. Fix: `@max_age` and `@min_age` in `Accounts.User`.

15. **Single-step pipe.** Rule: "Do not pipe a single step". Line 12, `params["email"] |> String.downcase()`. Fix: the downcase runs in the changeset with `update_change/3`.

16. **Options not validated or documented.** Rule: "Group related parameters": check options with `Keyword.validate!/2` and document them under `## Options`. Lines 6 and 5. Fix: `Keyword.validate!(opts, notify: false)` and a `@doc` with an `## Options` section.

17. **Comments that restate code, and no module or function docs.** Rule: "Comments explain why; documentation goes in `@moduledoc` and `@doc`". Lines 2, 5, 7, and 48 restate the code. Fix: the module comment becomes `@moduledoc`, the function comment becomes `@doc`, and the other two are deleted. The comment on line 11 explains a reason, so it stays and moves to the changeset.

18. **One long function with four levels of nesting.** Rule: "Keep functions short and at one level of detail". Lines 15 to 41. Fix: the public function is a `with` chain of named steps.

## Behavior changes

- Callers that matched `{:error, :invalid}` now receive `{:error, changeset}`.
- `return_id` and `silent` are removed.
- Ages over 120 are now stored as 120. Before this change they were stored unchanged, because of finding 1.
- A welcome email no longer includes the name "there" as a fallback. The nickname always has a value.

## Improved code

`lib/accounts/user_importer.ex`:

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV (comma-separated values) or JSON (JavaScript Object Notation) source.
  """

  alias Accounts.{Repo, User}

  @doc """
  Inserts one user from string-keyed `params`.

  Returns `{:ok, user}` or `{:error, changeset}`. Read the ID from `user.id`.

  ## Options

    * `:notify` - sends a welcome email after a successful insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, user} <- insert_user(params) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  defp insert_user(params) do
    %User{}
    |> User.import_changeset(params)
    |> Repo.insert()
  end

  defp send_welcome(user) do
    message = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(message) end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

The changeset goes in `Accounts.User` (`lib/accounts/user.ex`). The schema fields are assumed from the importer; the existing schema may differ.

```elixir
defmodule Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @max_age 120
  @min_age 18

  # ... existing schema, with `role` declared as an enum:
  #   field :role, Ecto.Enum, values: [:admin, :editor, :member]

  @doc """
  Casts and validates the fields of an import. Ages above `#{@max_age}` are capped at `#{@max_age}`.
  """
  def import_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :age, :role, :nickname])
    # The provider lowercases addresses before its uniqueness check, so match it here
    |> update_change(:email, &String.downcase/1)
    |> update_change(:age, &min(&1, @max_age))
    |> put_default_nickname()
    |> validate_required([:email, :age, :role])
    |> validate_number(:age, greater_than_or_equal_to: @min_age)
    |> unique_constraint(:email)
  end

  defp put_default_nickname(changeset) do
    nickname = get_field(changeset, :nickname) || get_field(changeset, :email)
    put_change(changeset, :nickname, nickname)
  end
end
```

## Notes

- The role names `:admin`, `:editor`, and `:member` are placeholders. Replace them with the project's real roles.
- The welcome email is built as a string and passed to `Mailer.deliver/1`. Check that `Mailer.deliver/1` accepts a string; the input file does the same and I could not confirm it.
- The improved code was not compiled or run, and it was not run through `mix format --check-formatted`. Writing to temporary directories was not permitted in this session. Run both before merging.
