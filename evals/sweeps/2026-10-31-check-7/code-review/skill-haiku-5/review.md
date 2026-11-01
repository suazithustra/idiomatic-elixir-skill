# Review: `Accounts.UserImporter`

The module can store wrong data without any error. The age cap never runs, and every failure, including bugs, comes back as `{:error, :invalid}`. The fix moves validation into a changeset (Ecto's validation and casting layer) and removes the broad `try`.

## Findings

1. The age cap never applies. Lines 15-17 rebind `age` inside an `if`, and that binding does not leave the block, so an age of 150 is stored as 150. Rule: assign the result of `if`, `case`, and `Enum` calls. Fix: clamp in the changeset with `update_change(:age, &min(&1, @max_age))`.

2. `String.to_atom(params["role"])` on line 8 turns caller input into atoms, and atoms are never freed (the VM has a fixed limit). Rule: convert external strings to atoms with explicit clauses. Fix: declare `role` as an `Ecto.Enum` field, so the changeset maps only the listed strings to atoms and rejects the rest.

3. The whole function sits in `try ... rescue _ -> {:error, :invalid}` (lines 10 and 42-43), which hides every bug as bad input. Rule: rescue only third-party code, never `rescue _ ->` around a whole function. Fix: remove the `try`; the changeset returns errors instead of raising.

4. `String.to_integer(params["age"])` on line 13 raises on input such as `"abc"`. Rule: use the non-raising version for expected failures. Fix: `cast/3` turns `"42"` into `42` and reports bad input as a changeset error, so the importer does not parse the age at all.

5. `params["email"] |> String.downcase()` on line 12 pipes a single step, and it raises when `email` is missing. Rule: do not pipe a single step. Fix: lowercase the address in the changeset with `update_change/3`, which runs only when the field is present.

6. Line 21 uses `&&` on `is_binary(email)` and `age >= 18`, which are both booleans. Rule: use `and` when the operands are booleans. Fix: the check moves into the changeset as `validate_number/3`, so no boolean operator remains in the importer.

7. Line 24 looks up the email with `Repo.get_by` and inserts only if nothing was found. Two imports of the same address can both pass the lookup. Rule: name the changeset facility, here `unique_constraint/3`, instead of a lookup before the insert. Fix: `unique_constraint(:email)` in the changeset turns the database's unique-index error into `{:error, changeset}`. The migration must also create a unique index on `email`.

8. Line 22 builds `%User{...}` and line 25 passes it straight to `Repo.insert/1`, so nothing is validated. Rule: cast and validate with a changeset. Fix: `User.import_changeset(%User{}, params)`, shown below.

9. The `_ -> {:error, :insert_failed}` clause on line 33 turns every other return value into one error. Rule: match every expected shape and let unexpected ones crash. Fix: `with {:ok, user} <- Repo.insert(...)` passes `{:error, changeset}` through unchanged.

10. Line 31, `if opts[:return_id], do: user.id, else: {:ok, user}`, makes an option change the return type. Rule: give each function one return shape. Fix: removed. Callers that need the ID read `user.id` from `{:ok, user}`.

11. Lines 27 and the `opts` list use two overlapping booleans, `:notify` and `:silent`. `:silent` only matters when `:notify` is true, so it adds nothing a caller cannot get by leaving `:notify` out. Rule: avoid overlapping booleans, and validate options with `Keyword.validate!/2` and document them under `## Options`. Fix: keep `:notify` only, validate with `Keyword.validate!(opts, notify: false)`, and document it in `@doc`.

12. Line 49, `spawn(fn -> ... end)`, starts a process outside any supervisor, so a crash goes unnoticed. The closure also captures the whole `user` struct, and the email is built inside the child process. Rule: supervise every long-lived process, and send processes only the data they need. Fix: build the email first and start it under `Accounts.TaskSupervisor` with `Task.Supervisor.start_child/2`.

13. Line 53, `user[:name]`, raises `UndefinedFunctionError`, because structs do not implement `Access`. The struct in this module also has no `name` field; it sets `nickname`. Rule: read required struct fields with dot access. Fix: `user.nickname`.

14. Line 55, `greeting |> (fn text -> ... end).()`, pipes into an anonymous function. Rule: do not pipe into an anonymous function call. Fix: one interpolated string.

15. `import_user/2` nests five levels deep (lines 10-44). Rule: keep functions short and at one level of detail; chain fallible steps with `with`. Fix: the validation moves into the changeset, and the insert is one `with` step.

16. The comments on lines 2, 5, 7, and 48 describe the module and functions, and two of them only restate the code. Rule: document modules and functions with `@moduledoc` and `@doc`, and keep only comments that give a reason. Fix: `@moduledoc` and `@doc` replace lines 2 and 5; lines 7 and 48 are deleted; line 11 moves next to the email normalization in the changeset.

## Assumptions

The improved code assumes the following. None of them is in the input file.

- `Accounts.User` has `field :role, Ecto.Enum, values: [...]` and a `:nickname` field. The role values below are placeholders for the ones your app uses.
- The migration has a unique index on `email`. Without it, `unique_constraint/3` never fires.
- `Accounts.TaskSupervisor` is started in the application's supervision tree.
- `User` has no `name` field, so the greeting uses `nickname`.
- Callers now receive `{:error, changeset}` instead of `{:error, :invalid}` or `{:error, :insert_failed}`, and the `:silent` and `:return_id` options are gone. Callers that match those values need changes.

## Improved code

`lib/accounts/user_importer.ex`

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV (comma-separated values) or JSON (JavaScript Object Notation) source.
  """

  alias Accounts.{Repo, User}

  @doc """
  Imports a single user from string-keyed params.

  Returns `{:ok, user}`, or `{:error, changeset}` when validation fails or the
  email is already taken.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, user} <- Repo.insert(User.import_changeset(%User{}, params)) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
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

Companion change in `Accounts.User` (`lib/accounts/user.ex`). The `schema` block is shown only to make the changeset's fields clear; keep your existing schema.

```elixir
defmodule Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @adult_age 18
  @max_age 120

  schema "users" do
    field :email, :string
    field :age, :integer
    field :nickname, :string
    field :role, Ecto.Enum, values: [:admin, :editor, :member]
    timestamps()
  end

  @doc false
  def import_changeset(user, params) do
    user
    |> cast(params, [:email, :age, :nickname, :role])
    |> validate_required([:email, :age, :role])
    # The provider lowercases addresses before its uniqueness check, so match it here
    |> update_change(:email, &String.downcase/1)
    |> update_change(:age, &min(&1, @max_age))
    |> validate_number(:age, greater_than_or_equal_to: @adult_age)
    |> put_nickname_default()
    |> unique_constraint(:email)
  end

  defp put_nickname_default(changeset) do
    if get_field(changeset, :nickname) do
      changeset
    else
      put_change(changeset, :nickname, get_field(changeset, :email))
    end
  end
end
```
