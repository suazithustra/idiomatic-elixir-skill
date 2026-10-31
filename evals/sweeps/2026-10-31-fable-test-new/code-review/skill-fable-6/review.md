# Review: `Accounts.UserImporter`

The module takes untrusted import rows and builds a `%User{}` by hand, so most of the validation it appears to do either does not run or crashes. The age cap never applies, the welcome email crashes on every send, a missing role crashes the whole call, and every other failure collapses into the same `{:error, :invalid}`. The fix is to move parsing and validation into an Ecto changeset, keep the importer as a short `with`, and run the mailer under a `Task.Supervisor`.

Rules come from `SKILL.md` and its `references/processes.md` and `references/ecto-phoenix.md`.

## Findings

**1. Comments restate the code and stand in for docs.** Rule: *Comments explain why; documentation goes in `@moduledoc` and `@doc`*. `# This module imports users from an external CSV/JSON source` (line 2), `# Import a single user from the given params` (line 5), `# Get the role from params` (line 7) and `# send the email` (line 48) say what the code already says. Fix: `@moduledoc` on the module, `@doc` with an `## Options` section on `import_user/2`, and delete the other three. The comment on line 11 about the provider lowercasing addresses explains a reason and stays.

**2. `String.to_atom/1` on external input.** Rule: *Convert external strings to atoms with explicit clauses*. `role = String.to_atom(params["role"])` (line 8) lets whoever controls the import file fill the atom table. It also sits outside the `try`, so a row with no role raises `ArgumentError` out of the function instead of returning an error. Fix: declare `field :role, Ecto.Enum, values: [...]` on the schema so `cast/3` accepts only the listed values and rejects the rest with a changeset error.

**3. `try/rescue _ ->` around the whole function.** Rule: *Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs*. Lines 10 and 42 to 44 wrap the body in `rescue _ -> {:error, :invalid}` to turn `String.to_integer/1` and `String.downcase/1` failures into a tuple, and in doing so also swallow every bug in the body. Fix: let `cast/3` parse `"age"` as `:integer` and report a bad value as a changeset error, and remove the `try`.

**4. Rebinding inside `if` does not escape it.** Rule: *Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it*. `if age > 120 do age = 120 end` (lines 15 to 17) rebinds a local copy, so `age` keeps its original value and the compiler warns about the unused variable. Fix: validate the range with `validate_number(:age, greater_than_or_equal_to: 18, less_than_or_equal_to: 120)`. This rejects rows over 120 instead of clamping them. The clamp never ran, so the current behavior is to accept them unchanged, and rejecting is the safer reading of what the code meant. If clamping is wanted, `update_change(:age, &min(&1, 120))` does it.

**5. Single-step pipe.** Rule: *Write pipelines that start with a value and read top to bottom*, "Do not pipe a single step". `email = params["email"] |> String.downcase()` (line 12) is one step. In the changeset version this becomes `update_change(:email, &String.downcase/1)`; written on its own it would be `String.downcase(params["email"])`.

**6. `&&` on boolean operands.** Rule: *Use `and`, `or`, `not` when the operands are booleans*. `if is_binary(email) && age >= 18 do` (line 21) has two boolean operands. The check is also dead, since `String.downcase/1` on line 12 already raised for a non-binary. Fix: `validate_required([:email, :age, :role])` and the `validate_number/3` call above replace both halves.

**7. Hand-built uniqueness check before insert.** Rule (`ecto-phoenix.md`): *Validate input with changesets*, "Declare database constraints in the changeset (`unique_constraint/3` ...)". `if Repo.get_by(User, email: email) == nil do` (line 24) is a lookup before an insert, which races with a concurrent import of the same address, and when it loses the race the insert raises. Fix: `unique_constraint(:email)` in the changeset, backed by the unique index, so a duplicate returns `{:error, changeset}`.

**8. Struct built from params and passed straight to `Repo.insert/1`.** Rule (`ecto-phoenix.md`): *Validate input with changesets*, "A `%User{}` built from the params and passed to `Repo.insert/1` is the pattern to replace". `user = %User{email: email, age: age, role: role, nickname: nickname}` (line 22) then `Repo.insert(user)` (line 25) inserts whatever was built with no validation. Fix: `%User{} |> User.import_changeset(params) |> Repo.insert()`, with the field handling in the changeset shown below.

**9. Catch-all `_ ->` on the insert result.** Rule: *Match every expected shape and let unexpected ones crash*. `_ -> {:error, :insert_failed}` (lines 33 to 34) hides what went wrong and will absorb any new return shape. Fix: with a changeset, `Repo.insert/1` returns `{:ok, user}` or `{:error, changeset}`, and the `with` passes the error through unchanged.

**10. Overlapping boolean options.** Rule: *Use one atom-valued field or option instead of overlapping booleans*. `if opts[:notify] && !opts[:silent] do` (line 27) has two options where one overrides the other, and `notify: true, silent: true` means nothing. Fix: keep `:notify` only, declare it with `Keyword.validate!(opts, notify: false)`, and document it under `## Options`.

**11. An option changes the return shape.** Rule: *Give each function one return shape*. `if opts[:return_id], do: user.id, else: {:ok, user}` (line 31) returns a bare integer in one mode and a tuple in the other, so callers cannot match on the result. Fix: drop `:return_id` and always return `{:ok, user}`; a caller that wants the id reads `user.id`.

**12. One error reason for every failure.** Rule: *Return `{:ok, value}` or `{:error, reason}` for expected failures*, "Callers can match on those". `{:error, :invalid}` is returned for a duplicate email (line 37), a bad age (line 40) and any exception (line 43), so a caller cannot tell a duplicate from a malformed row. Fix: `{:error, changeset}` carries the failing field and reason.

**13. Nested `if` and `case` five levels deep.** Rule: *Keep functions short and at one level of detail*, "When a `case`, `if`, or `with` appears inside another one, move the inner one into a named private function". Lines 15 to 41 nest `if` inside `case` inside `if` inside `if` inside `try`. Fix: the body becomes one `with` on `Repo.insert/1` once the checks live in the changeset.

**14. Bare `spawn/1` for the welcome email.** Rule (`processes.md`): *Supervise every long-lived process*, "A bare `spawn/1` or `Task.start/1` outside a supervisor has none of this", and the table entry "Fire-and-forget work: `Task.Supervisor.start_child/2`". `spawn(fn -> Mailer.deliver(welcome_email(user)) end)` (line 49) runs outside the supervision tree, so a crash is invisible and the process is not stopped on shutdown. Fix: `Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)`, with `{Task.Supervisor, name: Accounts.TaskSupervisor}` added to the application's children.

**15. The closure copies the whole user.** Rule (`processes.md`): *Send processes only the data they need*, "all variables captured by an anonymous function passed to `spawn/1` ... are copied". The closure on line 49 captures `user` to build the email inside the new process. Fix: build the email first, `email = welcome_email(user)`, and capture only that.

**16. `Access` on a struct.** Rule: *Read required keys with `map.key` or a pattern*, "Structs do not implement `Access`: `user[:name]` raises `UndefinedFunctionError`". `name = user[:name] || "there"` (line 53) raises on every call, and because it runs inside the spawned process the crash is never seen, so no welcome email has ever gone out. Fix: `user.nickname`, which the changeset guarantees is set (it defaults to the email). This assumes the greeting wants the nickname the importer just stored; the struct has no `name` field.

**17. Piping into an anonymous function.** Rule: *Write pipelines that start with a value and read top to bottom*, "Do not pipe into an anonymous function call". `greeting |> (fn text -> text <> " Enjoy your account." end).()` (line 55) does this, and `greeting = "Hi " <> name <> ", welcome!"` (line 54) is a binding used once. Fix: one interpolated string, `"Hi #{user.nickname}, welcome! Enjoy your account."`.

Not a finding: the `||` in `nickname = params["nickname"] || email` (line 19) is a correct truthy default. It moves into the changeset as `default_nickname/1` so it sees the downcased email.

## Improved code

Assumptions: the role values are `[:admin, :member]` (replace with the real set), `Accounts.TaskSupervisor` is started in the application supervision tree, the `users` table has a unique index on `email`, and `Mailer` is left as referenced in the original.

### `lib/accounts/user_importer.ex`

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.{Repo, User}

  @doc """
  Imports a single user from string-keyed `params`.

  Returns `{:ok, user}` or `{:error, changeset}`.

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

  defp welcome_email(user), do: "Hi #{user.nickname}, welcome! Enjoy your account."
end
```

### `lib/accounts/user.ex` (the changeset the importer relies on)

```elixir
defmodule Accounts.User do
  use Ecto.Schema

  import Ecto.Changeset

  @min_age 18
  @max_age 120

  schema "users" do
    field :email, :string
    field :age, :integer
    field :role, Ecto.Enum, values: [:admin, :member]
    field :nickname, :string
  end

  @doc """
  Builds the changeset for a user arriving from the external import source.
  """
  def import_changeset(user, params) do
    user
    |> cast(params, [:email, :age, :role, :nickname])
    # The provider lowercases addresses before its uniqueness check, so match it here
    |> update_change(:email, &String.downcase/1)
    |> validate_required([:email, :age, :role])
    |> validate_number(:age, greater_than_or_equal_to: @min_age, less_than_or_equal_to: @max_age)
    |> unique_constraint(:email)
    |> default_nickname()
  end

  defp default_nickname(changeset) do
    case get_field(changeset, :nickname) do
      nil -> put_change(changeset, :nickname, get_field(changeset, :email))
      _nickname -> changeset
    end
  end
end
```

## Verification

Both files pass `mix format --check-formatted` (with `locals_without_parens` for `field`, as `import_deps: [:ecto]` provides in a Mix project). `user_importer.ex` compiles with `elixir` against a stub `Accounts.User` struct; the only warnings are the expected "module not available" notices for `Accounts.Repo`, `Accounts.User.import_changeset/2` and `Mailer`, which live outside this file. `user.ex` was not compiled because Ecto is not available outside a Mix project.
