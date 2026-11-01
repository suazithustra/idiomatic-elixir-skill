# Review: `Accounts.UserImporter`

Assumptions: `Accounts.User` is an Ecto schema with a `name` field, and `Accounts.TaskSupervisor` can be added to the application's supervision tree. I could not compile or run the code here (no `User` schema, `Repo` or `Mailer` available).

## Findings

1. **Atom from external input** (rule: convert external strings to atoms with explicit clauses). `role = String.to_atom(params["role"])` lets anyone who controls the input exhaust the atom table. It also raises on a missing role. Fix: declare `role` as an `Ecto.Enum` field, so `cast/3` accepts only the listed values and returns a changeset error for the rest.

2. **`try/rescue _ ->` around the whole function** (rule: expected failures are tuples; never `rescue _`). `rescue _ -> {:error, :invalid}` hides every bug, including `Repo` and `Mailer` failures, behind one reason. Fix: remove it. `Integer.parse/1` and changeset validation replace `String.to_integer/1`, `String.downcase/1` on `nil` and the other raising calls.

3. **Rebinding inside `if` does not escape** (rule: assign the result of `if`). `if age > 120 do age = 120 end` leaves `age` unchanged and produces an unused-variable warning, so the cap never applies. Fix: `update_change(:age, &min(&1, @max_age))` in the changeset.

4. **Struct built from params and inserted** (Ecto rule: validate input with changesets). `%User{email: email, age: age, role: role, nickname: nickname}` goes to `Repo.insert/1` with no validation. Fix: `User.registration_changeset/2` using `cast/3`, `validate_required/2` and `validate_number/3`.

5. **Lookup before insert** (rule: declare constraints in the changeset). `Repo.get_by(User, email: email) == nil` followed by `Repo.insert(user)` is a race: two imports of the same email can both pass the check, and the second insert then raises. Fix: `unique_constraint(:email)`, which returns `{:error, changeset}`. The database needs a unique index on the lower-cased email, or on a `citext` column.

6. **`_ ->` clause and collapsed error reasons** (rule: match every expected shape; distinct reasons). `_ -> {:error, :insert_failed}` drops the changeset, and `{:error, :invalid}` is returned for a bad age, a bad email and a duplicate alike. Fix: return `{:error, changeset}` unchanged, so the caller sees which field failed and why.

7. **`&&` and `!` on booleans** (rule: `and`, `or`, `not` for booleans). `is_binary(email) && age >= 18` is replaced by the changeset. In the original, `is_binary(email)` also ran after `String.downcase(params["email"])` had already raised on a non-string, so the check could never fail usefully.

8. **Overlapping booleans** (rule: one atom-valued option instead of overlapping booleans). `opts[:notify] && !opts[:silent]` has a combination that makes no sense (`notify: true, silent: true`). Fix: one `:notify` option, validated with `Keyword.validate!/2` and documented under `## Options`.

9. **Option changes the return shape** (rule: one return shape per function). `if opts[:return_id], do: user.id, else: {:ok, user}` returns an id or a tuple. Fix: removed. Callers read `user.id` from `{:ok, user}`. If an id-only function is needed, add `import_user_id/2` on top of this one.

10. **Unsupervised `spawn`** (processes reference: supervise every long-lived process; send only the data needed). `spawn(fn -> Mailer.deliver(welcome_email(user)) end)` has no supervision and copies the whole `user` into the new process. Fix: build the email first, then `Task.Supervisor.start_child/2` with a closure that captures only the email.

11. **`user[:name]` on a struct** (rule: structs do not implement `Access`). It raises `UndefinedFunctionError`. Fix: `user.name || "there"`.

12. **Pipe into an anonymous function** (rule: no `|> (fn ... end).()`). `greeting |> (fn text -> ... end).()` is replaced by one interpolated string.

13. **Magic numbers** (rule: name them with module attributes). `120` and `18` become `@max_age` and `@min_age` in `User`.

14. **Comments and docs** (rule: comments explain why; `@moduledoc` and `@doc`). `# Get the role from params`, `# send the email` and `# Import a single user ...` restate the code or replace documentation. Fix: `@moduledoc`, `@doc` with `## Options`. The comment about the provider lowercasing addresses explains a reason, so it stays, next to the `downcase` it explains. I did not add `## Examples`, because the function needs a database and cannot run as a doctest.

15. **Deep nesting** (rule: short functions, one level of detail). `try` → `if` → `if` → `case` → `if` is gone. The public function is a `with` of one step, and the details are in private functions.

16. **Behaviour change to be aware of.** The function now returns `{:error, changeset}` where it used to return `{:error, :invalid}` or `{:error, :insert_failed}`. Callers that match those atoms need updating.

## Improved code

`lib/accounts/user.ex` (the parts that change):

```elixir
defmodule Accounts.User do
  use Ecto.Schema

  import Ecto.Changeset

  @min_age 18
  @max_age 120

  schema "users" do
    field :email, :string
    field :name, :string
    field :nickname, :string
    field :age, :integer
    field :role, Ecto.Enum, values: [:admin, :member]
  end

  @doc """
  Builds a changeset for a user imported from external data.

  Emails are lower-cased because the provider lowercases addresses before its
  uniqueness check. Ages above #{@max_age} are capped at #{@max_age}. The
  nickname defaults to the email.
  """
  def registration_changeset(user, params) do
    user
    |> cast(params, [:email, :age, :role, :nickname])
    |> validate_required([:email, :age, :role])
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

`lib/accounts/user_importer.ex`:

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.Repo
  alias Accounts.User

  @doc """
  Imports a single user from string-keyed `params`.

  Returns `{:ok, user}`, or `{:error, changeset}` when a field is missing or
  invalid or the email is already taken.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, user} <- insert_user(params) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  defp insert_user(params) do
    %User{}
    |> User.registration_changeset(params)
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
```

Required setup: add `{Task.Supervisor, name: Accounts.TaskSupervisor}` to the application's children, and a unique index on the lower-cased email in a migration.
