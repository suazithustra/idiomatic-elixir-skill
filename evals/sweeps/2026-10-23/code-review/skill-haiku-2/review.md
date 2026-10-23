# Review: `Accounts.UserImporter`

Source: `code-review-input.ex`. Rules are from the `idiomatic-elixir` skill.

## Findings

1. Line 8, `role = String.to_atom(params["role"])`. Any string in the import file becomes a new atom, and atoms are never freed, so a bad file can exhaust the atom table and crash the node. A missing role also raises here, outside the `try`. Rule: Convert external strings to atoms with explicit clauses. Fix: declare `role` as an `Ecto.Enum` field in the schema, so the changeset maps only the listed values and rejects the rest.

2. Lines 10 and 42-44, `try do` with `rescue _ -> {:error, :invalid}`. Any bug in the body, such as a typo, is reported as an invalid row, so it never surfaces. Rule: Rescue specific exceptions, never `rescue _ ->` around a whole function. Fix: remove the `try`. The changeset path does not raise on bad input.

3. Line 13, `age = String.to_integer(params["age"])`. A value such as `"abc"` raises. Rule: Do not wrap a raising call in `try/rescue`; use the non-raising version. Fix: `cast/3` in the changeset converts the string and returns an error for bad input.

4. Lines 15-17, `if age > 120 do` / `age = 120`. The new `age` exists only inside the `if`, so the clamp never applies and an age of 150 is saved as 150. Rule: Assign the result of `if`; rebinding inside a block does not escape it. Fix: `update_change(:age, &min(&1, 120))` in the changeset.

5. Line 12, `email = params["email"] |> String.downcase()`. A missing email raises, and the pipe has one step. Rule: Do not pipe a single step. Fix: move the lowercasing into the changeset with `update_change(:email, &String.downcase/1)`, which runs only on a value that cast accepted.

6. Line 21, `if is_binary(email) && age >= 18 do`. The `is_binary` check runs after `String.downcase` has already required a string, so it can never catch anything. `&&` also accepts non-boolean values. Rule: Use `and`, `or`, `not` when the operands are booleans. Fix: remove the check; `validate_required/2` and `validate_number/3` in the changeset do this work.

7. Lines 22-24, `user = %User{email: email, age: age, role: role, nickname: nickname}` followed by `if Repo.get_by(User, email: email) == nil do`. The importer checks for an existing email with a query and then inserts. Two imports of the same email can both pass the check, and the struct goes to `Repo.insert` with nothing validated. Rule: Validate input with changesets; use `unique_constraint/3` instead of a lookup before insert. Fix: `User.changeset(%User{}, params)` with `unique_constraint(:email)`. The unique index in the database makes the check safe, and a duplicate comes back as `{:error, changeset}`.

8. Lines 33-34, `_ ->` followed by `{:error, :insert_failed}`. Every failure becomes the same reason, and a new return value added later is hidden under it. Rule: Match every expected shape; let unexpected ones crash. Fix: match `{:error, _changeset} = error` and pass it through.

9. Line 31, `if opts[:return_id], do: user.id, else: {:ok, user}`. One option changes the return type, so callers cannot rely on one shape. Rule: Give each function one return shape. Fix: remove the option. Callers that need the id read `user.id` from `{:ok, user}`.

10. Line 27, `if opts[:notify] && !opts[:silent] do`. `notify` and `silent` are two booleans that overlap, and `notify: true, silent: true` is a contradiction the code settles without saying so. Rule: Use `and`/`not` for booleans, and prefer one option over overlapping booleans. Fix: remove `silent`, check the options with `Keyword.validate!/2`, and write `if opts[:notify]`. Callers that pass `silent:` now raise.

11. Lines 2, 5, 7, and 48 are comments that restate the code or describe the module, and `import_user/2` has no `@doc`. Rule: Comments explain why; documentation goes in `@moduledoc` and `@doc`. Fix: move the module description to `@moduledoc`, document the options in `@doc`, and delete the other comments. The comment on line 11 explains a reason, so it moves next to the lowercasing in the changeset.

12. Lines 15-45 nest `if`, `case`, and `if`/`else` four levels deep in one function. Rule: Keep functions short and at one level of detail; branch with function clauses and guards before `if`. Fix: validation moves to the changeset, and `import_user/2` becomes a short function: insert, then notify.

13. Line 49, `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`. A bare `spawn` has no supervisor, so a crash goes unreported and the process is invisible to tooling. Rule: Supervise every long-lived process; use `Task.Supervisor.start_child/2` for fire-and-forget work. Fix: `Task.Supervisor.start_child(Accounts.TaskSupervisor, Mailer, :deliver, [email])`. The application must start `{Task.Supervisor, name: Accounts.TaskSupervisor}`.

14. Line 53, `name = user[:name] || "there"`. `User` is a struct, and structs do not implement `Access`, so `user[:name]` raises `UndefinedFunctionError`. The struct also has no `name` field. Rule: Read struct fields with `user.field`. Fix: `user.nickname`, which the changeset always fills in (it defaults to the email).

15. Line 55, `greeting |> (fn text -> text <> " Enjoy your account." end).()`. Piping into an anonymous function is hard to read. Rule: Do not pipe into an anonymous function call. Fix: one interpolated string.

## Improved code

`user_importer.ex`:

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from external rows, such as CSV (comma-separated values) or
  JSON (JavaScript Object Notation) records with string keys.

  Validation and the uniqueness check live in `Accounts.User.changeset/2`.
  """

  alias Accounts.{Repo, User}

  @doc """
  Inserts one user from a row with string keys.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.

  Returns `{:ok, user}`, or `{:error, changeset}` when the row fails
  validation or the email is already taken.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)
    changeset = User.changeset(%User{}, params)

    case Repo.insert(changeset) do
      {:ok, user} ->
        if opts[:notify], do: send_welcome(user)
        {:ok, user}

      {:error, _changeset} = error ->
        error
    end
  end

  defp send_welcome(user) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, Mailer, :deliver, [email])
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

`user.ex` (the changeset the importer now calls; if the project's `User` already has a changeset, add these steps to it and keep the `role` values the project uses):

```elixir
defmodule Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :age, :integer
    field :role, Ecto.Enum, values: [:admin, :member]
    field :nickname, :string
    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :age, :role, :nickname])
    |> validate_required([:email, :age, :role])
    # The provider lowercases addresses before its uniqueness check, so match it here
    |> update_change(:email, &String.downcase/1)
    |> update_change(:age, &min(&1, 120))
    |> validate_number(:age, greater_than_or_equal_to: 18)
    |> put_default_nickname()
    |> unique_constraint(:email)
  end

  defp put_default_nickname(changeset) do
    if get_field(changeset, :nickname) do
      changeset
    else
      put_change(changeset, :nickname, get_field(changeset, :email))
    end
  end
end
```

## Changes that affect callers

- Failures return `{:error, changeset}`. The old reasons `:invalid` and `:insert_failed` are gone, so callers that match them must change.
- The `:return_id` and `:silent` options are removed. Passing `:silent` now raises `ArgumentError`.
- The `:role` values in `user.ex` (`:admin`, `:member`) are placeholders. Replace them with the project's roles.
- The age clamp now takes effect. Before, it never ran.
- The database needs a unique index on `users.email`, or `unique_constraint(:email)` cannot catch duplicates.
- `Accounts.TaskSupervisor` must be in the application's supervision tree.
