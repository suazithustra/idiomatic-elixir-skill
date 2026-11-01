# Review of `Accounts.UserImporter`

Elixir 1.17 or later and Ecto are assumed. The `User` schema was not provided, so some points below are assumptions and are marked as such.

## Findings

1. **`String.to_atom(params["role"])` (line 8).** Rule: convert external strings to atoms with explicit clauses. Anyone who controls the input can exhaust the atom table and crash the node. A missing `"role"` also raises `ArgumentError` outside the `try`. Fix: make `role` an `Ecto.Enum` field and let `cast/3` accept only the listed values.

2. **`try ... rescue _ -> {:error, :invalid}` around the whole function (lines 10, 42).** Rule: expected failures return tuples, and `rescue` never wraps a whole function. It hides real bugs, such as a `KeyError` or a database outage, behind the same `:invalid` as bad input. Fix: remove it and validate with a changeset.

3. **`String.to_integer(params["age"])` (line 13) and `params["email"] |> String.downcase()` (line 12).** Rules: use the non-raising version, and read required keys strictly. A missing or non-numeric value raises and is then swallowed by the `rescue`. Fix: `cast/3` and `validate_required/2` return `{:error, changeset}` that names the field.

4. **`if age > 120 do age = 120 end` (lines 15-17).** Rule: rebinding inside `if` does not escape the block. This is a no-op, and the compiler warns about an unused variable. The age is never capped. Fix: `update_change(:age, &min(&1, @max_age))` in the changeset, which keeps the evident intent of capping.

5. **`is_binary(email) && age >= 18` (line 21).** Rule: use `and` when the operands are booleans. `is_binary(email)` is also always true at that point, because `String.downcase/1` has already failed on anything else. Fix: `validate_number(:age, greater_than_or_equal_to: @min_age)`.

6. **`%User{...}` passed straight to `Repo.insert/1` (line 22).** Rule (Ecto reference): validate input with changesets. Nothing is validated, and a constraint violation raises. Fix: `User.changeset/2` plus `Repo.insert/1`.

7. **`Repo.get_by(User, email: email) == nil` before the insert (line 24).** Rule: declare database constraints in the changeset. The check and the insert are two steps, so two concurrent imports of the same email can both pass the check and one insert then fails. Fix: `unique_constraint(:email)`, which returns `{:error, changeset}`. The database needs a unique index on the lowercased email.

8. **`_ -> {:error, :insert_failed}` (line 33).** Rule: match every expected shape. This throws away the reason for the failure. Fix: pass `{:error, changeset}` through unchanged with `with`.

9. **Deeply nested `if`/`case`/`if` (lines 21-41).** Rules: keep functions short at one level of detail, and chain fallible steps with `with`. `{:error, :invalid}` appears twice for different causes. Fix: one `with` step over a small private function.

10. **`opts[:notify] && !opts[:silent]` (line 27).** Rule: use one atom-valued option instead of overlapping booleans. `notify: true, silent: true` makes no sense. Fix: a single `:notify` option, validated with `Keyword.validate!/2` and documented under `## Options`. `!` and `&&` are fine for a possibly-`nil` option, but the second option is not needed.

11. **`:return_id` changes the return shape (line 31).** Rule: give each function one return shape. It returns an integer or `{:ok, user}` depending on an option. Fix: remove the option. A caller who wants the id reads `user.id` from `{:ok, user}`. This is a behavior change for any caller that passes `return_id: true`.

12. **`spawn(fn -> Mailer.deliver(welcome_email(user)) end)` (line 49).** Rules (processes reference): supervise every long-lived process, and send processes only the data they need. A bare `spawn/1` has no supervisor and no error reporting. The closure copies the whole `user` struct and also builds the email inside the new process. Fix: build the email first, then `Task.Supervisor.start_child/2` with a closure that captures only the email. This assumes `{Task.Supervisor, name: Accounts.TaskSupervisor}` is started in the application's supervision tree.

13. **`user[:name]` (line 53).** Rule: structs do not implement `Access`. This raises `UndefinedFunctionError` on every welcome email, and because the email is built inside the spawned process, it fails silently. Fix: `user.name`. This assumes `User` has a `:name` field. If it does not, use `user.nickname`.

14. **`greeting |> (fn text -> ... end).()` (line 55).** Rules: do not pipe into an anonymous function call, and do not pipe a single step. Fix: one interpolated string.

15. **Comments that restate code** (`# Get the role from params`, `# send the email`, `# Import a single user ...`, the module comment). Rule: documentation goes in `@moduledoc` and `@doc`. Fix: add `@moduledoc` and `@doc` with `## Options` and `## Examples`. The comment on the provider's lowercasing is a real reason and is kept, moved next to the code that does the lowercasing.

16. **Magic numbers 18 and 120.** Rule: name magic numbers with module attributes. Fix: `@min_age` and `@max_age`.

17. **Alias before `@moduledoc`, no `@moduledoc`, no `@spec`.** Fix: `@moduledoc` first, then `alias`.

18. **Return shape change.** Invalid input now returns `{:error, %Ecto.Changeset{}}` instead of `{:error, :invalid}` or `{:error, :insert_failed}`, so callers can tell which field failed. Callers that match on the old atoms need updating.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.{Repo, User}

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

    with {:ok, user} <- insert_user(params) do
      if opts[:notify], do: send_welcome(user)

      {:ok, user}
    end
  end

  defp insert_user(params) do
    %User{}
    |> User.changeset(params)
    |> Repo.insert()
  end

  defp send_welcome(user) do
    email = welcome_email(user)

    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user) do
    name = user.name || "there"

    "Hi #{name}, welcome! Enjoy your account."
  end
end

defmodule Accounts.User do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @min_age 18
  @max_age 120

  @type t :: %__MODULE__{}

  schema "users" do
    field :email, :string
    field :name, :string
    field :nickname, :string
    field :age, :integer
    field :role, Ecto.Enum, values: [:admin, :editor, :member]
  end

  def changeset(user, params) do
    user
    |> cast(params, [:email, :age, :role, :nickname])
    |> validate_required([:email, :age, :role])
    # The provider lowercases addresses before its uniqueness check, so match it here
    |> update_change(:email, &String.downcase/1)
    |> update_change(:age, &min(&1, @max_age))
    |> validate_number(:age, greater_than_or_equal_to: @min_age)
    |> default_nickname()
    |> unique_constraint(:email)
  end

  defp default_nickname(changeset) do
    nickname = get_field(changeset, :nickname) || get_field(changeset, :email)

    put_change(changeset, :nickname, nickname)
  end
end
```

Notes on the improved code:

- The `Ecto.Enum` values (`:admin`, `:editor`, `:member`) and the `users` table are placeholders. Use the project's real roles and schema. If `Accounts.User` already exists, only add `changeset/2` to it.
- `Mailer` is kept as written in the input. If it is an application module, alias it under the `Accounts.` namespace.
- I did not run `mix format` or compile the code, because the schema, `Repo` and `Mailer` are not available here.
