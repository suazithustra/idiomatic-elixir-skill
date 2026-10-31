# Review of `Accounts.UserImporter`

The module builds a `%User{}` straight from untrusted string params, checks the fields by hand, wraps everything in a catch-all `rescue`, and collapses every failure into `{:error, :invalid}`. The welcome email crashes before it is sent, because it reads a struct with `user[:name]`. The fix is to move the validation into an `Ecto.Changeset` on `Accounts.User`, let the database unique index catch duplicate emails, give the function one return shape and one option, and send the email through a supervised task.

## Findings

1. **Convert external strings to atoms with explicit clauses.** `role = String.to_atom(params["role"])` creates an atom from whatever the source sends. Atoms are never garbage-collected, so a source that controls the input can exhaust the atom table and crash the node. This line is also outside the `try`, so a row without a role raises `ArgumentError` out of `import_user/2`. Fix: make `role` an `Ecto.Enum` field with the accepted values listed, so `cast/3` rejects anything else with a changeset error.

2. **Validate input with changesets (ecto-phoenix reference).** `user = %User{email: email, age: age, role: role, nickname: nickname}` followed by `Repo.insert(user)` inserts the struct as given, so nothing is validated and a constraint violation raises. Fix: `%User{} |> cast(params, [...]) |> validate_required(...) |> validate_number(...) |> Repo.insert()`, with the changeset defined as `User.import_changeset/1`.

3. **Declare database constraints in the changeset instead of a lookup before an insert (ecto-phoenix reference).** `if Repo.get_by(User, email: email) == nil do` is a check-then-insert race: two imports of the same email can both pass the check, and the second insert raises. Fix: `unique_constraint(:email)` in the changeset, which turns the violation into `{:error, changeset}`.

4. **Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs.** `rescue _ -> {:error, :invalid}` wraps the whole function and turns every exception, including bugs such as a `nil` email reaching `String.downcase/1`, into the same error. `age = String.to_integer(params["age"])` is the raising call it exists to catch. Fix: remove the `try`; `cast/3` parses `"age"` as an `:integer` field and reports a bad value in the changeset.

5. **Assign the result of `if`; rebinding inside a block does not escape it.** `if age > 120 do age = 120 end` never changes `age`, so the cap does nothing and the compiler warns about the unused inner variable. Fix: `update_change(:age, &min(&1, @max_age))` in the changeset.

6. **Use `and`, `or`, `not` when the operands are booleans.** `if is_binary(email) && age >= 18 do` uses `&&` on two booleans. The `is_binary` check is also dead: a non-binary email already raised in `String.downcase/1` on the line above. Fix: `validate_required([:email, ...])` and `validate_number(:age, greater_than_or_equal_to: @adult_age)` replace the whole condition.

7. **Match every expected shape and let unexpected ones crash.** `_ -> {:error, :insert_failed}` after `{:ok, user}` discards the changeset Ecto returns, so the caller cannot tell which field failed. Fix: `{:error, _changeset} = error -> error`.

8. **Use atoms or tagged tuples as error reasons the caller can match, and say which field failed (modeling data).** `{:error, :invalid}` is returned for an underage user, a duplicate email, a non-numeric age, and any exception, so callers cannot tell them apart. Fix: return the changeset, which carries one error per field.

9. **Use one atom-valued field or option instead of overlapping booleans.** `if opts[:notify] && !opts[:silent] do` is the pair the rule names: `silent: true` overrides `notify: true`, and the combination makes no sense. The options are also never validated or documented. Fix: keep only `:notify`, check it with `Keyword.validate!(opts, notify: false)`, and document it under `## Options` in `@doc`.

10. **Give each function one return shape.** `if opts[:return_id], do: user.id, else: {:ok, user}` makes the function return a bare integer in one mode and a tuple in the other, so a caller cannot pattern match the result without knowing which options were passed. Fix: drop `:return_id`; callers read `user.id` from `{:ok, user}`.

11. **Keep functions short and at one level of detail.** `import_user/2` nests `try`, `if`, `if`, `case`, and `if` five levels deep. Fix: one `case` on `Repo.insert/1`, with the validation in the changeset and the email in `send_welcome/1`.

12. **Supervise every long-lived process (processes reference).** `spawn(fn -> Mailer.deliver(welcome_email(user)) end)` starts an unsupervised process, so a crash in the mailer is lost and the process does not appear in Observer or shut down with the application. Fix: `Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(message) end)`, with `{Task.Supervisor, name: Accounts.TaskSupervisor}` added to the application's supervision tree.

13. **Send processes only the data they need (processes reference).** The closure above calls `welcome_email(user)` inside the spawned process, so the whole `%User{}` is copied into it. Fix: build the message first, `message = welcome_email(user)`, and capture only the string.

14. **Read required keys with `map.key` or a pattern; structs do not implement `Access`.** `name = user[:name] || "there"` raises `UndefinedFunctionError` on a `%User{}`, so the welcome email never sends and the crash is swallowed by the unlinked `spawn`. The struct built by this module has no `name` field; the field it always sets is `nickname`, which defaults to the email, so the `|| "there"` fallback is never needed. Fix: `user.nickname`.

15. **Do not pipe into an anonymous function call.** `greeting |> (fn text -> text <> " Enjoy your account." end).()` hides a string append inside a lambda call. Fix: one interpolated string, `"Hi #{user.nickname}, welcome! Enjoy your account."`.

16. **Comments explain why; documentation goes in `@moduledoc` and `@doc`.** `# This module imports users from an external CSV/JSON source` and `# Import a single user from the given params` are documentation written as comments, and `# Get the role from params` and `# send the email` restate the code. Fix: `@moduledoc` and `@doc`, delete the rest. The comment `# The provider lowercases addresses before its uniqueness check, so match it here` explains a reason the code cannot show, so it stays, now in the `@doc` of the changeset function.

17. **Add specs to public functions (library-design reference).** `def import_user(params, opts \\ [])` has no `@spec` and no guard on `params`, so a non-map argument fails inside Ecto rather than at the boundary. Fix: `@spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}` and `when is_map(params)`.

18. **Name magic numbers with module attributes.** `age > 120` and `age >= 18` are bare numbers. Fix: `@max_age 120` and `@adult_age 18`.

## Improved code

Assumptions: the `users` table has `email`, `age`, `role`, and `nickname` columns, matching the struct the original builds, and `role` is stored as a string. The accepted roles are not visible in the original, so `[:admin, :member]` is a placeholder to replace with the real list. `Accounts.TaskSupervisor` must be started in the application's supervision tree.

`lib/accounts/user_importer.ex`:

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.Repo
  alias Accounts.User

  @doc """
  Imports a single user from the string-keyed `params` of one source row.

  Returns `{:ok, user}` or `{:error, changeset}`. The changeset names the
  field that is missing or invalid, including an email that is already taken.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def import_user(params, opts \\ []) when is_map(params) do
    opts = Keyword.validate!(opts, notify: false)

    case Repo.insert(User.import_changeset(params)) do
      {:ok, user} ->
        if opts[:notify], do: send_welcome(user)
        {:ok, user}

      {:error, _changeset} = error ->
        error
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

`lib/accounts/user.ex` (the changeset the importer now relies on):

```elixir
defmodule Accounts.User do
  @moduledoc """
  A user account.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @adult_age 18
  @max_age 120

  schema "users" do
    field :email, :string
    field :age, :integer
    field :role, Ecto.Enum, values: [:admin, :member]
    field :nickname, :string

    timestamps()
  end

  @doc """
  Builds the changeset for a user imported from an external source.

  Lowercases the email because the provider lowercases addresses before its
  uniqueness check, caps the age at #{@max_age}, rejects users under
  #{@adult_age}, and uses the email as the nickname when none is given.
  """
  @spec import_changeset(map()) :: Ecto.Changeset.t()
  def import_changeset(params) do
    %__MODULE__{}
    |> cast(params, [:email, :age, :role, :nickname])
    |> validate_required([:email, :age, :role])
    |> update_change(:email, &String.downcase/1)
    |> update_change(:age, &min(&1, @max_age))
    |> validate_number(:age, greater_than_or_equal_to: @adult_age)
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

Add to the application's children list:

```elixir
{Task.Supervisor, name: Accounts.TaskSupervisor}
```

## Verification

`mix format --check-formatted` passes on the importer. On the schema it only asks for parentheses around `field`, which is because the check ran outside a Mix project where Ecto's `import_deps` formatter settings are not loaded; inside the project the form above is the standard one. `elixir user_importer.ex` compiles the importer with no warnings in its own code, only "module is not available" notices for `Accounts.Repo`, `Accounts.User`, and `Mailer`, which live elsewhere in the application. The schema module cannot be compiled standalone because it needs the Ecto dependency.
