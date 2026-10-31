# Review: `Accounts.UserImporter`

The module builds a `%User{}` straight from untrusted input and inserts it with no validation, checks for duplicate emails with a lookup that races against concurrent imports, and wraps everything in a catch-all `rescue` that turns bugs into `{:error, :invalid}`. The welcome email never sends, because `user[:name]` raises on a struct inside an unsupervised `spawn`, where nobody sees the crash. The fix is to move parsing and validation into an Ecto changeset with a unique constraint, give the function one return shape and one option, and send the email through a `Task.Supervisor`.

## Findings

**1. Struct built from params and inserted unvalidated** (ecto-phoenix: Validate input with changesets). Line 22, `user = %User{email: email, age: age, role: role, nickname: nickname}`, then line 25, `Repo.insert(user)`. Ecto inserts the struct as given, so nothing is validated and any constraint violation raises. Fix: `%User{} |> User.changeset(params) |> Repo.insert()`, with `cast/3`, `validate_required/2` and `validate_number/3` in the changeset.

**2. Lookup before insert instead of a unique constraint** (SKILL: report code that builds by hand what a rule names a facility for; ecto-phoenix: declare constraints in the changeset). Line 24, `if Repo.get_by(User, email: email) == nil do`. Two imports of the same address at once both pass the check and one raises on the database index. Fix: `unique_constraint(:email)` in the changeset, so the duplicate returns `{:error, changeset}`.

**3. `String.to_atom/1` on external input** (Convert external strings to atoms with explicit clauses). Line 8, `role = String.to_atom(params["role"])`. Whoever controls the CSV can create unlimited atoms and crash the node, and a missing role raises `ArgumentError` outside the `try`. Fix: `field :role, Ecto.Enum, values: [...]` so `cast/3` accepts only the listed values and rejects the rest as a changeset error.

**4. `try/rescue _ ->` around the whole function** (Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs). Lines 10 and 42 to 43, `rescue _ -> {:error, :invalid}`. It exists to catch `String.to_integer/1` and a `nil` email, but it also swallows every bug as `:invalid`. Fix: let `cast/3` parse the integer and report `{:error, changeset}`; remove the `rescue`.

**5. Rebinding inside `if` does not escape the block** (Assign the result of `if`, `case`, and `Enum` calls). Lines 15 to 17, `if age > 120 do age = 120 end`. The outer `age` is unchanged, the compiler warns, and an age of 200 is imported as 200. Fix: `age = min(age, 120)`, which in the changeset is `update_change(:age, &min(&1, @max_age))`. The improved version keeps the clamp the author intended; I would reject the row instead, with `less_than_or_equal_to: @max_age`, because silently rewriting imported data hides a problem at the source.

**6. `_ ->` clause after `{:ok, user}`** (Match every expected shape and let unexpected ones crash). Lines 33 to 34, `_ -> {:error, :insert_failed}`. `Repo.insert/1` returns `{:error, changeset}`, which says which field failed; the catch-all discards that and would also hide a new return shape. Fix: pass the `{:error, changeset}` through, which `with` does unasked.

**7. `&&` and `!` on boolean operands, and a dead check** (Use `and`, `or`, `not` when the operands are booleans). Line 21, `if is_binary(email) && age >= 18 do`, and line 27, `opts[:notify] && !opts[:silent]`. `is_binary(email)` is always true here, because `String.downcase/1` on line 12 already raised otherwise. Fix: `and` and `not` where booleans are combined; in the improved version the age check moves to `validate_number/3` and the options collapse to one, so neither expression remains.

**8. Overlapping boolean options, unvalidated** (Use one atom-valued field or option instead of overlapping booleans; Group related parameters). Line 27, `if opts[:notify] && !opts[:silent] do`. `silent` only overrides `notify`, so `notify: true, silent: true` means nothing, and a misspelled option is ignored. Fix: keep `:notify` alone, check it with `Keyword.validate!(opts, notify: false)`, and document it under `## Options`.

**9. Two return shapes from one function** (Give each function one return shape). Line 31, `if opts[:return_id], do: user.id, else: {:ok, user}`. A caller matching `{:ok, user}` gets a bare integer when the option is set. Fix: always return `{:ok, user}`; the caller reads `user.id`.

**10. Four levels of nested `if`, `case` and `if`** (Keep functions short and at one level of detail; Chain fallible steps with `with`). Lines 15 to 41. The public function should read as a sequence of named steps. Fix: validate the options, insert the changeset inside a `with`, and call a private `send_welcome/1` for the side effect.

**11. Bare `spawn/1` that copies the whole user** (processes: Supervise every long-lived process; Send processes only the data they need). Line 49, `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`. The process is outside any supervisor, so its crash is invisible, and the closure copies the entire `%User{}` to build one string. Fix: build the message first and run `Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)`. `Accounts.TaskSupervisor` must be a child in the application's supervision tree.

**12. `user[:name]` on a struct** (Read required keys with `map.key` or a pattern; structs do not implement `Access`). Line 53, `name = user[:name] || "there"`. This raises `UndefinedFunctionError` every time, inside the spawned process, so no welcome email has ever been delivered. The importer sets `nickname` and defaults it to the email, so the `|| "there"` branch is dead too. Fix: `user.nickname`.

**13. Pipe into an anonymous function call** (Write pipelines that start with a value; do not pipe into an anonymous function call). Line 55, `greeting |> (fn text -> text <> " Enjoy your account." end).()`. Fix: one interpolated string, `"Hi #{user.nickname}, welcome! Enjoy your account."`.

**14. Single-step pipe** (Do not pipe a single step). Line 12, `email = params["email"] |> String.downcase()`. Fix: `String.downcase(params["email"])`; in the improved version this is `update_change(:email, &String.downcase/1)` in the changeset.

**15. Comments where documentation belongs, and comments that restate the code** (Comments explain why; documentation goes in `@moduledoc` and `@doc`). Line 2, `# This module imports users from an external CSV/JSON source`; line 5, `# Import a single user from the given params`; line 7, `# Get the role from params`; line 48, `# send the email`. Fix: `@moduledoc`, `@doc` with `## Options`, and a `@spec` (library-design: give every public function a `@spec`). Delete the two restating comments. The comment on line 11 explains a reason the code cannot show and stays, next to the downcase in the changeset.

## Improved code

`lib/accounts/user_importer.ex`:

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.{Repo, User}

  @doc """
  Imports a single user from string-keyed `params`.

  Returns `{:ok, user}` or `{:error, changeset}`; a duplicate email comes back
  as a changeset error on `:email`.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, user} <- Repo.insert(User.changeset(%User{}, params)) do
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

Findings 1 to 6 and 14 are fixed in the changeset, which belongs on the schema. The importer relies on `Accounts.User` providing the following; the schema was not part of the input, so the field list and the `Ecto.Enum` values are placeholders to reconcile with the real one:

```elixir
defmodule Accounts.User do
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @min_age 18
  @max_age 120

  schema "users" do
    field :email, :string
    field :nickname, :string
    field :age, :integer
    field :role, Ecto.Enum, values: [:admin, :member]

    timestamps()
  end

  def changeset(user, params) do
    user
    |> cast(params, [:email, :nickname, :age, :role])
    |> validate_required([:email, :age, :role])
    # The provider lowercases addresses before its uniqueness check, so match it here
    |> update_change(:email, &String.downcase/1)
    |> update_change(:age, &min(&1, @max_age))
    |> validate_number(:age, greater_than_or_equal_to: @min_age)
    |> default_nickname()
    |> unique_constraint(:email)
  end

  defp default_nickname(changeset) do
    case get_field(changeset, :nickname) do
      nil -> put_change(changeset, :nickname, get_field(changeset, :email))
      _nickname -> changeset
    end
  end
end
```

## Behaviour changes to be aware of

- Errors are now `{:error, %Ecto.Changeset{}}` instead of `{:error, :invalid}` or `{:error, :insert_failed}`. Callers that matched the atoms need updating.
- The `:silent` and `:return_id` options are gone. `Keyword.validate!/2` raises if a caller still passes them, which is the point: it surfaces every call site.
- The welcome email greets by `nickname`, not `name`. The old code never sent an email at all, so there is no delivered behaviour to preserve.
- `Mailer` is left as written. If it is this application's own module it belongs under `Accounts` (Naming: put every module under the top-level namespace), but that is a change to a module outside this review.

## Verification

Elixir 1.20.3 is installed. `mix format --check-formatted` passes on both files, with `field` in the formatter's `locals_without_parens` as `import_deps: [:ecto]` provides in a real project. The importer compiles with `elixir` against stub `User`, `Repo` and `Mailer` modules with no warnings. The schema module was not compiled, since Ecto is not available outside a Mix project.
