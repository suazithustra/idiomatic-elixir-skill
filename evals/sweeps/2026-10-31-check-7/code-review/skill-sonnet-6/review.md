# Review: `Accounts.UserImporter`

The importer does validation by hand, hides every failure behind `{:error, :invalid}`, and has two bugs: the age cap never takes effect, and `welcome_email/1` crashes on a `%User{}`. The fix moves validation into an `Ecto.Changeset` (Ecto's validation and constraint tool) and leaves the importer as a short pipeline.

## Findings

1. **Bug: the age cap does nothing.** Rule: "Assign the result of `if`...; rebinding inside a block does not escape it".
   `if age > 120 do age = 120 end` rebinds `age` only inside the `if`, so an age of 200 passes through unchanged. Fix: clamp with `min/2` in the changeset.

2. **Bug: `user[:name]` on a struct.** Rule: "Read required keys with `map.key`...; structs do not implement `Access`".
   `name = user[:name] || "there"` raises `UndefinedFunctionError` because `user` is a `%User{}`. Fix: `user.name`. This assumes `User` has a `:name` field. The importer never sets one, so the greeting is usually "there".

3. **`String.to_atom/1` on external input.** Rule: "Convert external strings to atoms with explicit clauses".
   `role = String.to_atom(params["role"])` lets any caller grow the atom table, and raises on a missing role. Fix: make `role` an `Ecto.Enum` field, so `cast/3` accepts only the listed roles and returns a changeset error for the rest.

4. **`try/rescue _ ->` around the whole function.** Rule: "Return `{:ok, value}`...; raise only for bugs".
   It turns every bug (including the `KeyError`s and `MatchError`s above) into `{:error, :invalid}`. `String.to_integer/1` and `String.downcase(nil)` are what it was catching. Fix: remove it. `cast/3` parses and rejects bad ages, and `validate_required/2` rejects missing fields.

5. **Struct built by hand and handed to `Repo.insert/1`.** Rule (`ecto-phoenix.md`): "Validate input with changesets".
   `%User{email: email, ...}` skips validation, and the age check is written out by hand. Fix: `User.changeset/2` with `cast/3`, `validate_required/2` and `validate_number/3`.

6. **Lookup before insert.** Rule: `unique_constraint/3`.
   `Repo.get_by(User, email: email) == nil` has a race (two imports can both pass the check), and costs an extra query. Fix: `unique_constraint(:email)` in the changeset, backed by a unique index.

7. **`_ ->` clause and one reason for every failure.** Rule: "Match every expected shape and let unexpected ones crash".
   `_ -> {:error, :insert_failed}` and four different failures all returning `:invalid` leave the caller unable to tell a duplicate email from an age under 18. Fix: return `{:error, changeset}` from `Repo.insert/1` unchanged.

8. **`&&` and `!` on booleans, and overlapping options.** Rules: "Use `and`, `or`, `not`..." and "Use one atom-valued field or option instead of overlapping booleans".
   `is_binary(email) && age >= 18` should be `and`. `opts[:notify] && !opts[:silent]` has `notify: true, silent: true` as a nonsense combination. Fix: keep only `:notify`, validated with `Keyword.validate!/2`.

9. **`:return_id` changes the return shape.** Rule: "Give each function one return shape".
   `if opts[:return_id], do: user.id, else: {:ok, user}` returns a bare integer or a tuple depending on an option. Fix: always return `{:ok, user}`. A caller wanting the id reads `user.id`.

10. **Unsupervised `spawn/1`.** Rule (`processes.md`): "Supervise every long-lived process".
    A crash in `Mailer.deliver/1` is lost, and shutdown does not wait for the send. Fix: `Task.Supervisor.start_child/2` under `Accounts.TaskSupervisor` (must be added to the supervision tree). The email is built before the call so the closure captures only the email, not the user.

11. **`is_binary(email)` after `String.downcase(email)`.** The check can never fail, because `downcase` already raised on a non-binary. Fix: gone with the changeset.

12. **Piping into an anonymous function.** Rule: "Write pipelines that start with a value...".
    `greeting |> (fn text -> ... end).()` is a single string. Fix: one interpolated string.

13. **Comments and docs.** Rule: "Comments explain why; documentation goes in `@moduledoc` and `@doc`".
    The comments `# Get the role from params`, `# send the email` and the two header comments restate the code. Fix: delete them, add `@moduledoc` and `@doc` with `## Options` and an `## Examples` section. The comment about the provider lowercasing addresses explains a reason, so it is kept, on the changeset.

14. **Unaliased `Mailer`, and the alias group.** `Mailer` is used without an alias (assumed to be `Accounts.Mailer`). The grouped alias is expanded to one per line so the list matches the other modules in the project.

15. **Magic number.** Rule: "Name magic numbers with module attributes". `120` becomes `@max_age`, and `18` becomes `@min_age` in the changeset.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.Mailer
  alias Accounts.Repo
  alias Accounts.User

  @doc """
  Imports a single user from string-keyed `params`.

  Returns `{:ok, user}`, or `{:error, changeset}` when a field is missing or
  invalid, the age is under 18, or the email is already taken.

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

    {:ok, _pid} = Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user) do
    name = user.name || "there"

    "Hi #{name}, welcome! Enjoy your account."
  end
end
```

`opts[:notify]` is used for a value with a default, per the rule. The `if ..., do:` without `else` stays on one line because it is one plain call.

`User` changes (assumes `role` is declared as an `Ecto.Enum`, for example `field :role, Ecto.Enum, values: [:admin, :editor, :member]`, with the real role names substituted, and that a unique index on `email` exists):

```elixir
@max_age 120
@min_age 18

def import_changeset(user, params) do
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
  if get_field(changeset, :nickname) do
    changeset
  else
    put_change(changeset, :nickname, get_field(changeset, :email))
  end
end
```

Behaviour changes callers must know about: failures are now `{:error, %Ecto.Changeset{}}` instead of `{:error, :invalid}` or `{:error, :insert_failed}`; the `:silent` and `:return_id` options are removed; an unknown role is a changeset error instead of a new atom.

Not run: the sandbox check was skipped because there is no Mix project or `User` schema here to compile against.
