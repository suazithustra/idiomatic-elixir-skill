# Review: `Accounts.UserImporter`

The module validates each imported user by hand, with nested `if`s inside a `try/rescue` that swallows every error, so a bad record is indistinguishable from a bug and callers cannot tell which field was wrong. It also builds atoms from external input, checks email uniqueness with a query that races with concurrent imports, and sends the welcome email from an unsupervised process. The fix is to move validation into an `Ecto.Changeset`, which handles casting, required fields, the age range, the role enum and the unique index, and to run the email through a `Task.Supervisor`.

## Findings

**1. Module and function documented with comments (lines 2, 5).** Rule: "Comments explain why; documentation goes in `@moduledoc` and `@doc`". `# This module imports users from an external CSV/JSON source` and `# Import a single user from the given params` are documentation, not comments. Move them into `@moduledoc` and `@doc`, and document the option under `## Options`. Add a `@spec` directly above the `def`.

**2. Comments that restate the code (lines 7, 48).** Same rule. `# Get the role from params` and `# send the email` say what the next line already says. Delete them. The comment on line 11, `# The provider lowercases addresses before its uniqueness check, so match it here`, explains a reason and stays.

**3. Role converted with `String.to_atom/1` on external input (line 8).** Rule: "Convert external strings to atoms with explicit clauses", and the Ecto reference's "Use `Ecto.Enum` for fields with a fixed set of atom values". `role = String.to_atom(params["role"])` lets whoever controls the import file create unbounded atoms, and raises `ArgumentError` when `"role"` is missing because the call sits outside the `try`. Declare `role` as an `Ecto.Enum` field on the schema and let `cast/3` reject any value not in the list.

**4. Whole function wrapped in `try/rescue _ ->` (lines 10, 42-43).** Rule: "Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs", which says never `rescue _ ->` around a whole function. The `rescue` exists to catch `String.to_integer/1` on a non-numeric age and `String.downcase/1` on a missing email, but it also turns a typo, a database outage or a struct without a field into `{:error, :invalid}`. Cast `age` as an `:integer` field so the changeset reports a non-numeric value, and remove the `try`.

**5. Required keys read with `params["key"]` and `nil` checks (lines 8, 12, 13).** Rule: "Parse external data into structs where it enters the system", and the Ecto reference's "Validate input with changesets". `email = params["email"] |> String.downcase()` crashes when the key is absent. Pass `params` to `cast/3` and `validate_required([:email, :age, :role])`; the resulting changeset names the missing field.

**6. Single step piped (line 12).** Rule: "Write pipelines that start with a value and read top to bottom", which says do not pipe a single step. `params["email"] |> String.downcase()` becomes `String.downcase(params["email"])`. In the improved version the lowercasing is `update_change(:email, &String.downcase/1)` inside the changeset pipeline.

**7. Rebinding inside `if` has no effect (lines 15-17).** Rule: "Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it". `if age > 120 do age = 120 end` leaves the outer `age` unchanged and the compiler warns about an unused variable, so the cap never applies. Write `age = min(age, 120)`, or in the changeset `update_change(:age, &min(&1, @max_age))`. The improved version keeps the cap, since the code's intent was to clamp rather than reject.

**8. `&&` and `!` on boolean operands (lines 21, 27).** Rule: "Use `and`, `or`, `not` when the operands are booleans". `if is_binary(email) && age >= 18 do` should be `and`; `opts[:notify] && !opts[:silent]` should be `and not`. The `is_binary(email)` check is also redundant, since `String.downcase/1` has already raised on a non-binary. Both conditions disappear in the improved version: the age bound is `validate_number(:age, greater_than_or_equal_to: @min_age)` and the `:silent` option is removed (finding 12).

**9. Struct built from params and inserted without validation (lines 22, 25).** Ecto reference, "Validate input with changesets": "A `%User{}` built from the params and passed to `Repo.insert/1` is the pattern to replace." `user = %User{email: email, age: age, role: role, nickname: nickname}` then `Repo.insert(user)` inserts whatever arrived. Replace with `%User{} |> cast(params, [...]) |> validate_required(...) |> Repo.insert()`.

**10. Lookup before insert instead of a unique constraint (line 24).** Ecto reference, "Validate input with changesets": declare constraints in the changeset so a violation returns `{:error, changeset}`. `if Repo.get_by(User, email: email) == nil do` is two queries where one will do, and two concurrent imports of the same address both pass the check and one then raises on the index. Replace with `unique_constraint(:email)` on the changeset, backed by `create unique_index(:users, [:email])` in a migration.

**11. Nested `if` inside `if` inside `case`, all collapsing to `{:error, :invalid}` (lines 15-41).** Rules: "Keep functions short and at one level of detail" and "Match every expected shape and let unexpected ones crash". Three different failures (under age, duplicate email, insert failed) and every rescued exception return the same `{:error, :invalid}`, so the caller cannot report what was wrong with the record. The changeset gives one branch, `Repo.insert/1`, whose `{:error, changeset}` carries the field and message.

**12. Overlapping boolean options `:notify` and `:silent` (line 27).** Rule: "Use one atom-valued field or option instead of overlapping booleans", whose example is this exact call. `if opts[:notify] && !opts[:silent] do` makes `notify: true, silent: true` a legal, meaningless combination. Keep `notify: true` only. Rule "Group related parameters" also asks for `Keyword.validate!(opts, notify: false)` so an unknown option raises at the call site.

**13. Option changes the return shape (line 31).** Rule: "Give each function one return shape". `if opts[:return_id], do: user.id, else: {:ok, user}` returns an integer in one mode and a tuple in the other, so no caller can match the result without knowing the options. Always return `{:ok, user}`; a caller that wants the id reads `user.id`. The `:return_id` option is removed.

**14. `_ ->` clause hides the insert error (lines 33-34).** Rule: "Match every expected shape and let unexpected ones crash". `_ -> {:error, :insert_failed}` discards the changeset that says why the insert failed. `Repo.insert/1` returns `{:ok, user}` or `{:error, changeset}`; pass the error through unchanged. With one step whose body cannot fail, that is `with {:ok, user} <- Repo.insert(changeset) do ... end`, per "Chain fallible steps with `with`".

**15. Bare `spawn/1` for the welcome email (line 49).** Processes reference, "Supervise every long-lived process" and the table row "Fire-and-forget work: `Task.Supervisor.start_child/2`". `spawn(fn -> Mailer.deliver(welcome_email(user)) end)` is invisible to supervisors and tooling, and a crash in it is lost. Start it with `Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> ... end)`, with `{Task.Supervisor, name: Accounts.TaskSupervisor}` added to the application's children.

**16. Closure copies the whole user into the task (line 49).** Processes reference, "Send processes only the data they need". The closure captures `user`, so the entire struct is copied into the new process to build one string. Build the email in the caller, `email = welcome_email(user)`, and capture only `email`.

**17. `Access` on a struct (line 53).** Rule: "Read required keys with `map.key` or a pattern", which notes structs do not implement `Access`. `name = user[:name] || "there"` raises `UndefinedFunctionError` on every call, so the welcome email never sends. The struct built on line 22 has no `name` field at all; the only greeting-friendly field is `nickname`, which always holds a value after the import. Read `user.nickname`.

**18. Pipe into an anonymous function (line 55).** Rule: "Write pipelines that start with a value and read top to bottom", which says do not pipe into `(fn ... end).()`. `greeting |> (fn text -> text <> " Enjoy your account." end).()` is one string literal written as a pipeline. Write `"Hi #{user.nickname}, welcome! Enjoy your account."`.

**19. `use`, `import`, `alias` grouping (line 3).** Rule: "Open a module with `use`, `import`, `alias`, `require`, in that order". The improved module needs `import Ecto.Changeset`; it goes above the `alias` line, right after `@moduledoc`.

## Improved code

Assumptions, stated because they are outside this file: `Accounts.User` is an Ecto schema whose `role` is an `Ecto.Enum` with the application's role list, `users.email` has a unique index, and `Accounts.TaskSupervisor` is started in the application's supervision tree. A minimal shape for the schema follows the module.

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.

  Each record arrives as a string-keyed map and is validated with a changeset
  before it is inserted.
  """

  import Ecto.Changeset

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user.

  `params` is a string-keyed map with `"email"`, `"age"` and `"role"`, and an
  optional `"nickname"` that defaults to the email address. Ages above 120 are
  capped at 120.

  Returns `{:ok, user}` or `{:error, changeset}`; the changeset names the
  field that was missing, invalid or already taken.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, user} <- Repo.insert(import_changeset(params)) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  defp import_changeset(params) do
    %User{}
    |> cast(params, [:email, :age, :role, :nickname])
    |> validate_required([:email, :age, :role])
    # The provider lowercases addresses before its uniqueness check, so match it here
    |> update_change(:email, &String.downcase/1)
    |> default_nickname()
    |> update_change(:age, &min(&1, @max_age))
    |> validate_number(:age, greater_than_or_equal_to: @min_age)
    |> unique_constraint(:email)
  end

  defp default_nickname(changeset) do
    if is_nil(get_field(changeset, :nickname)) do
      put_change(changeset, :nickname, get_field(changeset, :email))
    else
      changeset
    end
  end

  defp send_welcome(user) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user), do: "Hi #{user.nickname}, welcome! Enjoy your account."
end
```

Schema shape the importer relies on. Replace the role values with the application's own list; a migration must add `create unique_index(:users, [:email])`.

```elixir
defmodule Accounts.User do
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "users" do
    field :email, :string
    field :age, :integer
    field :role, Ecto.Enum, values: [:admin, :member]
    field :nickname, :string
  end
end
```

## Verification

`mix format --check-formatted` passes on the improved module. It compiles with no warnings under Elixir 1.20.3 against stubbed `Ecto.Changeset`, `Accounts.Repo`, `Accounts.User` and `Mailer` modules; a full compile needs the real Ecto dependency and the schema above.
