# Review: `Accounts.UserImporter`

## Findings

1. **The clamp on age never runs.** `if age > 120 do age = 120 end` rebinds `age` inside the `if`, and the outer `age` keeps its value. An age of 150 is saved as 150. Rule: *Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it.* Fix: clamp with `update_change(:age, &min(&1, 120))` in the changeset.

2. **Atoms are created from input.** `String.to_atom(params["role"])` creates an atom from external data, which can exhaust the atom table. A missing `"role"` key also crashes the function, because `String.to_atom(nil)` raises. Rule: *Convert external strings to atoms with explicit clauses.* Fix: declare `role` as an `Ecto.Enum` field, so the changeset rejects unknown values.

3. **`try/rescue _` hides every error.** The `rescue _ -> {:error, :invalid}` clause catches bugs as well as bad input, and the caller cannot tell a missing field from a bad number. Rule: *Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs.* Fix: remove the `try`. `String.to_integer/1` is replaced by the changeset's cast, and each failure is reported in the changeset.

4. **The email check runs after the email is used.** `String.downcase(params["email"])` raises when the key is missing, and `is_binary(email)` on the next lines comes too late to help. Rule: *Match every expected shape and let unexpected ones crash* and *Parse external data into structs where it enters the system.* Fix: `validate_required/2` in the changeset.

5. **`&&` is used on booleans.** `is_binary(email) && age >= 18` should use `and`, which also checks that both operands are booleans. Rule: *Use `and`, `or`, `not` when the operands are booleans.* Fix: the changeset's `validate_number/3` replaces the check.

6. **Look-up before insert.** `Repo.get_by(User, email: email) == nil` followed by `Repo.insert/1` can let two imports insert the same email, because the gap between the two calls is not protected. Rule: a changeset with `unique_constraint/3` reports the duplicate. Fix: `unique_constraint(:email)` in the changeset, and the database error comes back as `{:error, changeset}`.

7. **A raw struct is inserted.** `%User{email: ..., age: ...}` goes to `Repo.insert/1` without a changeset, so no validation runs. Rule: *Cast and validate external input with `Ecto.Changeset`.* Fix: `User.import_changeset/2`, then `Repo.insert/1` on the changeset.

8. **A catch-all clause hides insert errors.** `_ -> {:error, :insert_failed}` turns every failure into one reason. Rule: *Match every expected shape and let unexpected ones crash.* Fix: pass the changeset back as `{:error, changeset}`.

9. **Overlapping options.** `opts[:notify] && !opts[:silent]` combines two booleans that overlap: `silent` only has an effect when `notify` is set. Rule: *Use one atom-valued field or option instead of overlapping booleans.* Fix: drop `:silent`. `notify: false`, the default, already sends no email. Callers that pass `silent: true` must remove that option.

10. **The return shape depends on an option.** `if opts[:return_id], do: user.id, else: {:ok, user}` makes `import_user/2` return either an integer or a tuple. Rule: *Give each function one return shape.* Fix: always return `{:ok, user}`. Callers that used `return_id: true` read `user.id` instead.

11. **Unsupervised `spawn`.** `spawn/1` starts a process that no supervisor tracks, so it is not restarted and does not appear in monitoring tools. The closure also captures the whole `user`. Rule: *Supervise every long-lived process* and *Send processes only the data they need.* Fix: build the email first, then start it with `Task.Supervisor.start_child/2`. The supervisor must be in the application's supervision tree.

12. **`user[:name]` on a struct.** Structs do not implement `Access`, so `user[:name]` raises `UndefinedFunctionError`. Rule: *Read required keys with `map.key` or a pattern.* Fix: read `user.nickname`, the field the importer sets. The "there" default stays for a missing nickname.

13. **A pipe into an anonymous function.** `greeting |> (fn text -> ... end).()` is hard to read, and the same text can be an interpolated string. Rule: *Do not pipe into an anonymous function call.* Fix: `"Hi #{name}, welcome! Enjoy your account."`.

14. **Comments where docs belong.** The `#` comments above the module and the function restate the code or describe the API. Rule: *Document modules and public functions with `@moduledoc` and `@doc`, not with comments above them.* Fix: `@moduledoc` and `@doc` with the options listed. The comments that restate code are deleted. The comment about lowercasing the email is replaced by the changeset, which does the lowercasing where the field is cast.

## Improved code

Two modules. `Accounts.User` is a sketch: the file was not provided, so the field list and the `Ecto.Enum` role values (`:admin`, `:member`) are placeholders to replace with the project's own.

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external source.
  """

  alias Accounts.{Repo, User}

  @doc """
  Imports a single user from string-keyed params.

  Returns `{:ok, user}` or `{:error, changeset}`.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    changeset = User.import_changeset(%User{}, params)

    with {:ok, user} <- Repo.insert(changeset) do
      if opts[:notify], do: send_welcome(user)

      {:ok, user}
    end
  end

  defp send_welcome(user) do
    email = welcome_email(user)

    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user) do
    name = user.nickname || "there"

    "Hi #{name}, welcome! Enjoy your account."
  end
end

defmodule Accounts.User do
  use Ecto.Schema

  import Ecto.Changeset

  @max_age 120
  @min_age 18

  schema "users" do
    field :email, :string
    field :age, :integer
    field :role, Ecto.Enum, values: [:admin, :member]
    field :nickname, :string

    timestamps()
  end

  @doc false
  def import_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :age, :role, :nickname])
    |> validate_required([:email, :age, :role])
    |> update_change(:email, &String.downcase/1)
    |> validate_number(:age, greater_than_or_equal_to: @min_age)
    |> update_change(:age, &min(&1, @max_age))
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

Notes on the rewrite:

- The importer assumes `Accounts.TaskSupervisor` is started in the application's supervision tree: `{Task.Supervisor, name: Accounts.TaskSupervisor}`.
- Errors are now `{:error, changeset}` instead of `{:error, :invalid}`. Callers that match on `:invalid` must read the changeset's errors instead.
- The welcome email is still sent after the insert succeeds. The insert and the email are not in one transaction, so an email can go out if a later step in the caller fails.
