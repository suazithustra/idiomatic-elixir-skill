# Review: `Accounts.UserImporter`

The module takes a row from an external CSV (comma-separated values) or JSON file, builds a user by hand, checks it with nested `if`s, and reports every failure as the same `{:error, :invalid}`. Most of the hand-written checks have a facility in Ecto (the database library) that does the job and names the failing field. The improved version moves validation into a changeset, keeps one return shape, and runs the welcome email under a supervisor.

## Findings

**1. Documentation lives in comments.** Lines 2 and 5, `# This module imports users from an external CSV/JSON source` and `# Import a single user from the given params`, describe the module and its public function, and `# Get the role from params` (line 7) and `# send the email` (line 48) restate the code. Rule: comments explain why; documentation goes in `@moduledoc` and `@doc`. Fix: a `@moduledoc`, a `@doc` with an `## Options` section on `import_user/2`, and delete the comments that restate the code. The one comment worth keeping, "The provider lowercases addresses before its uniqueness check", explains a reason and moves into the changeset's `@doc`.

**2. External strings become atoms.** Line 8, `role = String.to_atom(params["role"])`, lets whoever controls the import file create an unbounded number of atoms, which the VM (virtual machine) never frees, so a large file can crash the node. It also runs outside the `try`, so a row with no role raises `FunctionClauseError` instead of returning an error. Rule: convert external strings to atoms with explicit clauses; the Ecto reference names `Ecto.Enum` for a field with a fixed set of atom values. Fix: `field :role, Ecto.Enum, values: [:admin, :editor, :viewer]` on the schema, so `cast/3` accepts the listed strings and adds a changeset error for anything else.

**3. A whole-function `rescue` hides every error.** Lines 10 and 42 to 43 wrap the body in `try ... rescue _ -> {:error, :invalid}`, so a typo, a database outage, and a bad age all look the same to the caller. Rule: return `{:ok, value}` or `{:error, reason}` for expected failures and never `rescue _ ->` around a whole function; call the non-raising version instead. Fix: `cast/3` turns `"age" => "abc"` into a changeset error, so neither `String.to_integer/1` (line 13) nor the `try` is needed.

**4. Single-step pipe.** Line 12, `email = params["email"] |> String.downcase()`. Rule: do not pipe a single step. Fix: in the changeset, `update_change(:email, &String.downcase/1)`, which also runs only when an email is present, where the original raises on a missing one.

**5. The age cap never applies.** Lines 15 to 17, `if age > 120 do age = 120 end`, rebind `age` inside the block; the outer `age` keeps its value and the compiler warns about an unused variable. Rule: assign the result of `if`; rebinding inside a block does not escape it. Since the cap never ran, no caller depends on it, and silently rewriting an imported value hides a bad source row, so the fix rejects the row instead: `validate_number(:age, greater_than_or_equal_to: @min_age, less_than_or_equal_to: @max_age)`, with both limits named as module attributes rather than the magic numbers 18 and 120.

**6. `&&` on boolean operands.** Line 21, `if is_binary(email) && age >= 18 do`. Rule: use `and`, `or`, `not` when the operands are booleans. In the improved version the check becomes `validate_required([:email, :age, :role])` plus the `validate_number/3` above, so no operator is needed.

**7. A struct is built from params and inserted unvalidated.** Lines 22 and 25, `user = %User{email: email, age: age, role: role, nickname: nickname}` and `Repo.insert(user)`. Ecto rule: validate input with changesets; a `%User{}` built from params and passed to `Repo.insert/1` is the pattern to replace, because nothing is validated and a constraint violation raises. Fix: `%User{} |> cast(params, [:email, :nickname, :age, :role]) |> ... |> Repo.insert()` through a `User.import_changeset/1`.

**8. Lookup before insert instead of a unique constraint.** Line 24, `if Repo.get_by(User, email: email) == nil do`. Two imports of the same address at the same time both pass the check and one then raises inside the `rescue`. Ecto rule: declare `unique_constraint/3` in the changeset so a violation returns `{:error, changeset}`. Fix: `unique_constraint(:email)` and drop the query.

**9. Catch-all clause on the insert result.** Line 33, `_ -> {:error, :insert_failed}`. Rule: match every expected shape and let unexpected ones crash. Fix: `{:error, _changeset} = error -> error`, which also gives the caller the field that failed.

**10. Overlapping boolean options.** Line 27, `if opts[:notify] && !opts[:silent] do`: `notify: true, silent: true` makes no sense, and one option overrides the other. Rule: use one atom-valued field or option instead of overlapping booleans; check options with `Keyword.validate!/2` and document them under `## Options`. Fix: a single `:notify` option, `Keyword.validate!(opts, notify: false)`.

**11. An option changes the return shape.** Line 31, `if opts[:return_id], do: user.id, else: {:ok, user}`, returns a bare integer in one mode and a tuple in the other. Rule: give each function one return shape. Fix: always return `{:ok, user}`; a caller that wants the id reads `user.id`.

**12. Four levels of nested branching.** Lines 15 to 41 nest `if` inside `if` inside `if` inside `case`. Rule: keep functions short and at one level of detail; when a `case` or `if` appears inside another one, move the inner one into a named private function. Fix: with validation in the changeset, `import_user/2` is one `case` on `Repo.insert/1`.

**13. Unsupervised `spawn` that copies the whole user.** Line 49, `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`. Processes reference: a bare `spawn/1` outside a supervisor is invisible to shutdown, restarts and Observer; fire-and-forget work goes through `Task.Supervisor.start_child/2`. The closure also captures the full `user` struct, and everything a spawned closure captures is copied; send processes only the data they need. Fix: build the email first, then `Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)`. `Accounts.TaskSupervisor` must be started in the application's supervision tree.

**14. Access syntax on a struct.** Line 53, `name = user[:name] || "there"`. Rule: structs do not implement `Access`, so `user[:name]` raises `UndefinedFunctionError`; read struct fields with `user.name`. The struct also has no `name` field, so the welcome email has never been built successfully. The field the code sets is `nickname`, which always holds a value (it defaults to the email), so the `|| "there"` fallback is dead too. Fix: `user.nickname`.

**15. Pipe into an anonymous function.** Line 55, `greeting |> (fn text -> text <> " Enjoy your account." end).()`. Rule: do not pipe into an anonymous function call. Fix: one interpolated string, `"Hi #{user.nickname}, welcome! Enjoy your account."`.

## Improved code

Both files pass `mix format --check-formatted`. The importer compiles standalone with `elixir user_importer.ex`, with only the expected warnings that `Accounts.Repo`, `Accounts.User` and `Mailer` are not defined in that file.

`lib/accounts/user_importer.ex`:

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.Repo
  alias Accounts.User

  @doc """
  Imports one user from the string-keyed `params` of a source row.

  Returns `{:ok, user}` or `{:error, changeset}`, where the changeset
  names the field that was missing, invalid, or already taken.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
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
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

The importer depends on a changeset in `Accounts.User`, which was not part of the input. This is what it needs from that module. The role values are a placeholder, since the original accepted any string; replace them with the roles the system actually has.

`lib/accounts/user.ex`:

```elixir
defmodule Accounts.User do
  use Ecto.Schema

  import Ecto.Changeset

  @min_age 18
  @max_age 120

  schema "users" do
    field :email, :string
    field :nickname, :string
    field :age, :integer
    field :role, Ecto.Enum, values: [:admin, :editor, :viewer]

    timestamps()
  end

  @doc """
  Builds the changeset for a user imported from an external source.

  The provider lowercases addresses before its uniqueness check, so the
  email is lowercased here to match it. A missing nickname defaults to
  the email.
  """
  def import_changeset(params) do
    %__MODULE__{}
    |> cast(params, [:email, :nickname, :age, :role])
    |> update_change(:email, &String.downcase/1)
    |> put_default_nickname()
    |> validate_required([:email, :age, :role])
    |> validate_number(:age, greater_than_or_equal_to: @min_age, less_than_or_equal_to: @max_age)
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

`unique_constraint(:email)` needs a unique index on `users.email` in a migration, and `Accounts.TaskSupervisor` needs a `{Task.Supervisor, name: Accounts.TaskSupervisor}` entry in the application's children list.
