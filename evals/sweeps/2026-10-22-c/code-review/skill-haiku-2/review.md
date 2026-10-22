# Review: `Accounts.UserImporter`

Rules are from `idiomatic-elixir` (SKILL.md) and its `references/ecto-phoenix.md` and `references/processes.md`, which this module triggers through `Repo`/`Ecto` and `spawn`.

## Findings

Most severe first.

1. **Real bug: the age cap never applies.** Rule: *Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it.*
   Line 15-17: `if age > 120 do age = 120 end`. The rebinding stays inside the `if`, so ages above 120 are stored as given. Fix: clamp with `update_change(:age, &min(&1, @max_age))` in the changeset.

2. **Bug: welcome emails silently never send.** Rule: *Access on structs* (`map.key` for a struct; structs do not implement `Access`).
   Line 53: `name = user[:name] || "there"`. `user` is a `%User{}`, so this raises `UndefinedFunctionError`. The call sits inside the `spawn` closure (line 49), so only the spawned process crashes and nothing reports it. Fix: `"Hi #{user.nickname}, welcome! Enjoy your account."`. `nickname` is always set by the changeset, so the `"there"` fallback is dead.

3. **Catch-all `rescue` around the whole function.** Rule: *Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs*; a `rescue _ ->` is forbidden.
   Lines 10 and 42-44: `try do ... rescue _ -> {:error, :invalid} end`. It turns every bug, including a missing `params["email"]`, into `{:error, :invalid}`. Fix: no `try`. The changeset returns `{:error, changeset}` for bad input, and nothing raises.

4. **Atom created from external input.** Rule: *Convert external strings to atoms with explicit clauses*.
   Line 8: `role = String.to_atom(params["role"])`. Any caller can exhaust the atom table, and a missing key raises outside the `try`. Fix: declare `role` as `Ecto.Enum` on the schema and let `cast/3` convert it.

5. **Raising converters for expected bad input.** Rule: *Return tuples for expected failures; call the non-raising version*.
   Line 13: `String.to_integer(params["age"])` raises on `"abc"`. Line 12: `String.downcase/1` raises on `nil`. Fix: `cast/3` and `validate_number/3` handle both.

6. **Single-step pipe.** Rule: *Do not pipe a single step*.
   Line 12: `params["email"] |> String.downcase()`. Fix: `update_change(:email, &String.downcase/1)` in the changeset.

7. **Validation by hand instead of a changeset; struct inserted directly.** Rule: *Validate input with changesets*.
   Lines 21 and 22: `if is_binary(email) && age >= 18 do` followed by `%User{email: email, age: age, role: role, nickname: nickname}`. Ecto inserts the struct as given, so nothing is validated. Fix: `User.import_changeset/2` runs `validate_required/2` and `validate_number/3`.

8. **Lookup before insert.** Rule: *Declare database constraints in the changeset (`unique_constraint/3`)*.
   Line 24: `if Repo.get_by(User, email: email) == nil do`. This check races with concurrent inserts. Fix: `unique_constraint(:email)`. The database enforces uniqueness and the insert returns `{:error, changeset}`.

9. **Catch-all after a success clause.** Rule: *Match every expected shape and let unexpected ones crash*.
   Lines 33-34: `_ -> {:error, :insert_failed}`. It hides the changeset errors and any new return shape. Fix: `{:error, _changeset} = error -> error`.

10. **`&&` and `!` on booleans.** Rule: *Use `and`, `or`, `not` when the operands are booleans*.
    Lines 21 and 27: `is_binary(email) && age >= 18` and `opts[:notify] && !opts[:silent]`. Fix: removed with findings 7 and 11.

11. **Overlapping booleans.** Rule: *Use one atom-valued field or option instead of overlapping booleans*.
    Line 27: `opts[:notify] && !opts[:silent]`. `silent` only overrides `notify`, so the pair has a contradictory state (`notify: true, silent: true`). Fix: drop `:silent` and keep `notify: true`, as the rule's example does.

12. **Option changes the return shape.** Rule: *Give each function one return shape*.
    Line 31: `if opts[:return_id], do: user.id, else: {:ok, user}`. Fix: `import_user/2` always returns `{:ok, user}`, and `import_user_id/2` returns `{:ok, id}`.

13. **Options not validated or documented.** Rules: *Group related parameters* (`Keyword.validate!/2`, `## Options` in `@doc`) and *Comments explain why; documentation goes in `@doc`*.
    Line 6 has no `@doc`. Fix: `opts = Keyword.validate!(opts, notify: false)` and a `@doc` with `## Options`.

14. **Comments restate the code, and the module doc is a comment.** Rules: *Delete comments that restate the code*; *Document modules … with `@moduledoc`*.
    Line 2: `# This module imports users from …` becomes `@moduledoc`. Lines 5, 7 and 48 (`# Import a single user…`, `# Get the role from params`, `# send the email`) are deleted. Line 11 explains a reason (the provider lowercases before its uniqueness check), so it stays, moved to the changeset.

15. **Bare `spawn`.** Rule: *Supervise every long-lived process*.
    Line 49: `spawn(fn -> ... end)`. Fix: `Task.Supervisor.start_child(Accounts.TaskSupervisor, ...)`. The supervisor must be in the application's children (see notes).

16. **Closure captures the whole user.** Rule: *Send processes only the data they need*.
    Line 49: `fn -> Mailer.deliver(welcome_email(user)) end` copies `user` into the new process. Fix: build `message` first, then capture only `message`.

17. **Pipe into an anonymous function.** Rule: *Do not pipe into an anonymous function call*.
    Lines 54-55: `greeting |> (fn text -> text <> " Enjoy your account." end).()`. Fix: a single interpolated string. The `<>` chain on line 54 becomes interpolation as well, which reads better.

18. **Errors conflated under one atom.** Rule: *Use atoms, tagged tuples, or exception structs as error reasons*; callers need to match the reason.
    Lines 37 and 40 return `{:error, :invalid}` for both a duplicate email and an age under 18. The changeset carries the field and the message for each. Fix: return `{:error, changeset}`.

## Improved version

`lib/accounts/user_importer.ex`:

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.{Repo, User}

  @doc """
  Imports a single user from the given params.

  Returns `{:ok, user}`, or `{:error, changeset}` when the params are invalid
  or the email is already taken.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)
    changeset = User.import_changeset(%User{}, params)

    case Repo.insert(changeset) do
      {:ok, user} ->
        if opts[:notify], do: send_welcome(user)
        {:ok, user}

      {:error, _changeset} = error ->
        error
    end
  end

  @doc """
  Imports a single user like `import_user/2`, and returns the new user's ID.
  """
  def import_user_id(params, opts \\ []) do
    case import_user(params, opts) do
      {:ok, user} -> {:ok, user.id}
      {:error, _changeset} = error -> error
    end
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

`lib/accounts/user.ex` (the changeset this module now calls; the schema and changeset must match your existing `User`):

```elixir
defmodule Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @max_age 120

  schema "users" do
    field :email, :string
    field :age, :integer
    field :nickname, :string
    field :role, Ecto.Enum, values: [:member, :editor, :admin]
    timestamps()
  end

  @doc """
  Casts and validates the params of an imported user.

  Ages above #{@max_age} are capped at #{@max_age}. Users under 18 are rejected.
  """
  def import_changeset(user, params) do
    user
    |> cast(params, [:email, :age, :role, :nickname])
    |> validate_required([:email, :age, :role])
    # The provider lowercases addresses before its uniqueness check, so match it here
    |> update_change(:email, &String.downcase/1)
    |> update_change(:age, &min(&1, @max_age))
    |> validate_number(:age, greater_than_or_equal_to: 18)
    |> default_nickname()
    |> unique_constraint(:email)
  end

  defp default_nickname(changeset) do
    nickname = get_field(changeset, :nickname) || get_field(changeset, :email)
    put_change(changeset, :nickname, nickname)
  end
end
```

Notes:

- The `@doc` in `User` interpolates `@max_age` into a heredoc. That works, but if you prefer, write "120" literally.

## Behavior changes and assumptions

- **Callers that pass `silent:` or `return_id:` now get `ArgumentError`** from `Keyword.validate!/2`. `return_id:` moved to `import_user_id/2`. `silent:` is gone; use `notify:` alone.
- **Failures return `{:error, changeset}`** instead of `{:error, :invalid}` or `{:error, :insert_failed}`. Callers matching those atoms need updating.
- **Unknown roles are rejected** by `Ecto.Enum`. The values in `User` are placeholders; replace them with your real roles.
- **Ages above 120 are now capped**, as the original code intended. Existing rows with uncapped ages are not changed.
- **Welcome emails start sending.** They never did before, because the `user[:name]` crash ran inside the spawned process.
- **Requires** a unique index on `users.email` (for `unique_constraint/3` to work), and `{Task.Supervisor, name: Accounts.TaskSupervisor}` in the application's supervision tree.
- **Not reported:** `Mailer` is aliased nowhere, so it is a top-level module. The rule for app namespacing needs the application name, which this file does not show, so I left it alone.
- **Not verified by compiling.** The module was not run; the `User` companion is written to match this module's calls and should be checked against the real schema.
