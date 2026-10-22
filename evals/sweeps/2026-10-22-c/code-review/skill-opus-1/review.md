# Review: `Accounts.UserImporter`

References read: `SKILL.md`, `references/ecto-phoenix.md` (Repo, schema), `references/processes.md` (`spawn`).

## Findings

### Correctness and safety

1. **Convert external strings to atoms with explicit clauses.** `role = String.to_atom(params["role"])` lets whoever controls the import source create new atoms until the node hits the atom limit and crashes. It also raises on a missing role, and that error is outside the `try`, so it is not rescued.
   **Fix:** declare `field :role, Ecto.Enum, values: [...]` and cast `role` in the changeset. Unknown values then come back as changeset errors.

2. **Assign the result of `if`; rebinding inside a block does not escape it.** In `if age > 120 do age = 120 end`, the inner `age` is local to the block, so the cap never applies and the compiler warns that the variable is unused.
   **Fix:** `update_change(:age, &min(&1, @max_age))` in the changeset. Outside a changeset, `age = min(age, 120)` would do.

3. **Structs do not implement `Access`.** In `welcome_email/1`, `user[:name]` on a `%User{}` raises `UndefinedFunctionError`. That happens inside the spawned process, so the welcome email always fails and nobody sees the error. The struct shown also has no `name` field.
   **Fix:** read the field directly with `user.nickname`, which the changeset makes sure is set (it defaults to the email).

4. **Validate input with changesets / `unique_constraint/3` (ecto-phoenix).** The function builds `%User{email: ..., age: ..., role: ..., nickname: ...}` by hand, checks `is_binary(email) && age >= 18` by hand, and passes the struct to `Repo.insert/1`, which validates nothing. `if Repo.get_by(User, email: email) == nil do` builds a uniqueness check by hand. It is also a race: two concurrent imports can both see `nil`, and then the second insert raises on the unique index.
   **Fix:** use `User.import_changeset/2` with `cast/3`, `validate_required/2`, `validate_number/3` and `unique_constraint(:email)`, then call `Repo.insert/1`. A duplicate email then returns `{:error, changeset}`.

5. **Return `{:ok, value}` / `{:error, reason}`; do not wrap raising calls in `try/rescue`.** `try do ... rescue _ -> {:error, :invalid} end` wraps the whole function. It turns every bug (`String.downcase(nil)`, `String.to_integer("abc")`, DB connection errors, typos) into `{:error, :invalid}`.
   **Fix:** remove the `try`. Casting through the changeset handles bad integers and missing fields without raising.

6. **Match every expected shape and let unexpected ones crash.** `_ -> {:error, :insert_failed}` after `{:ok, user}` throws away the changeset that explains the failure.
   **Fix:** `{:error, _changeset} = error -> error`.

7. **Supervise every long-lived process / send processes only the data they need (processes).** `spawn(fn -> Mailer.deliver(welcome_email(user)) end)` starts an unsupervised process, so crashes go unseen and nothing shuts it down cleanly. It also copies the whole `user` into the new process.
   **Fix:** build the email in the caller, then call `Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)`. This needs `{Task.Supervisor, name: Accounts.TaskSupervisor}` in the application's supervision tree.

### API design

8. **Give each function one return shape.** `if opts[:return_id], do: user.id, else: {:ok, user}` makes an option change the return type from a tuple to an integer.
   **Fix:** drop `:return_id`. The function always returns `{:ok, user}`, and callers read `user.id`.

9. **Use one option instead of overlapping booleans.** `opts[:notify] && !opts[:silent]` has two booleans where one overrides the other.
   **Fix:** keep only `notify: true`.

10. **Group related parameters / `Keyword.validate!/2`.** The options are not checked, so a misspelled option is silently ignored.
    **Fix:** `opts = Keyword.validate!(opts, notify: false)`, with the option documented under `## Options`.

11. **Use `and`, `or`, `not` when the operands are booleans.** `is_binary(email) && age >= 18` and `opts[:notify] && !opts[:silent]` use the truthy operators on booleans. Both expressions disappear with the changeset and the single option. The notify branch now uses `maybe_send_welcome/2` with `true`/`false` clauses, which also crashes on a non-boolean value.

### Readability

12. **Keep functions short / move nested `case`/`if` into named functions.** `import_user/2` nests `try` → `if` → `if` → `case` → `if` five levels deep, and repeats `{:error, :invalid}` in two branches.
    **Fix:** `import_user/2` now validates the options, calls `insert_user/1`, and on success calls `maybe_send_welcome/2`.

13. **Comments explain why; documentation goes in `@moduledoc` and `@doc`.**
    - `# This module imports users from an external CSV/JSON source` becomes a `@moduledoc`.
    - `# Import a single user from the given params` becomes a `@doc` with `## Options` and a `@spec`.
    - `# Get the role from params` and `# send the email` restate the code, so they are deleted.
    - `# The provider lowercases addresses before its uniqueness check, so match it here` explains a reason the code can't show, so it is kept next to the `String.downcase` step.

14. **Do not pipe a single step.** `params["email"] |> String.downcase()` becomes `&String.downcase/1` inside the changeset pipeline.

15. **Do not pipe into an anonymous function call.** `greeting |> (fn text -> text <> " Enjoy your account." end).()` becomes a single interpolated string.

16. **Read required keys with `map.key` or a pattern.** `params["email"]` and `params["age"]` are required, but `[]` access returns `nil`, so the failure shows up later as a `FunctionClauseError` inside `String.downcase/1`. `cast/3` plus `validate_required/2` now reports exactly which fields are missing.

17. **Name magic numbers with module attributes.** `120` and `18` become `@max_age` and `@min_age`.

18. **Naming: every module under its application's namespace.** `Mailer` is called as a top-level module. It is aliased as `Accounts.Mailer` in the improved version. This is an assumption: if the project's mailer lives somewhere else, alias that module instead.

### Behaviour changes to note

- Errors are now `{:error, %Ecto.Changeset{}}` instead of `:invalid` / `:insert_failed`. Callers that matched those atoms need updating, but they can now see which field failed and why.
- `:return_id` and `:silent` are removed. Passing either one now raises from `Keyword.validate!/2`, so stale call sites show up immediately.
- The welcome greeting uses the nickname. Previously it could never work, because `user[:name]` always raised.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.{Mailer, Repo, User}

  @doc """
  Imports a single user from string-keyed `params`.

  Returns `{:ok, user}`, or `{:error, changeset}` when the params are invalid
  or the email is already taken.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    case insert_user(params) do
      {:ok, user} ->
        maybe_send_welcome(user, opts[:notify])
        {:ok, user}

      {:error, _changeset} = error ->
        error
    end
  end

  defp insert_user(params) do
    %User{}
    |> User.import_changeset(params)
    |> Repo.insert()
  end

  defp maybe_send_welcome(user, true), do: send_welcome(user)
  defp maybe_send_welcome(_user, false), do: :ok

  defp send_welcome(user) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user), do: "Hi #{user.nickname}, welcome! Enjoy your account."
end
```

The changeset this relies on belongs in `Accounts.User`. This is a sketch: adjust the role values to the real schema, which should declare `field :role, Ecto.Enum, values: [:member, :admin]`.

```elixir
defmodule Accounts.User do
  use Ecto.Schema

  import Ecto.Changeset

  @max_age 120
  @min_age 18

  # schema "users" do ... field :role, Ecto.Enum, values: [:member, :admin] ... end

  @doc """
  Builds a changeset for a user imported from an external source.
  """
  def import_changeset(user, params) do
    user
    |> cast(params, [:email, :age, :role, :nickname])
    |> validate_required([:email, :age, :role])
    # The provider lowercases addresses before its uniqueness check, so match it here
    |> update_change(:email, &String.downcase/1)
    |> update_change(:age, &min(&1, @max_age))
    |> validate_number(:age, greater_than_or_equal_to: @min_age)
    |> put_default_nickname()
    |> unique_constraint(:email)
  end

  defp put_default_nickname(changeset) do
    case get_field(changeset, :nickname) do
      nil -> put_change(changeset, :nickname, get_field(changeset, :email))
      _nickname -> changeset
    end
  end
end
```

Also add `{Task.Supervisor, name: Accounts.TaskSupervisor}` to the application's supervision tree.

Verification: `mix format` ran on the code and made no changes. The code was not compiled, because there is no Mix project with Ecto here.
