# Review: Accounts.UserImporter

## Findings

1. **Atom from external input (Convert external strings to atoms).** `role = String.to_atom(params["role"])` lets the input exhaust the VM atom table. It also raises on `nil`, and the `rescue` hides that. Fix: make `role` an `Ecto.Enum` field and let `cast/3` reject unknown values.

2. **Struct inserted without validation (Ecto: validate input with changesets).** `Repo.insert(%User{...})` validates nothing. Fix: `User.changeset/2` with `cast`, `validate_required`, `validate_number`.

3. **Lookup before insert (Ecto: `unique_constraint/3`).** `Repo.get_by(User, email: email) == nil` followed by `Repo.insert` is a race: two imports can both pass the check. Fix: `unique_constraint(:email)` in the changeset, which needs a unique index on `email`. A duplicate returns `{:error, changeset}`.

4. **`try/rescue _ ->` around the whole function (Return tuples for expected failures).** It swallows every bug, including the `MatchError` from `nil` input, and returns `:invalid`. `String.to_integer/1` and `String.downcase(nil)` raise on bad input. Fix: drop the `try` and let `cast/3` do the parsing, so bad input gives `{:error, changeset}`.

5. **Rebinding inside `if` (Assign the result of `if`).** `if age > 120 do age = 120 end` leaves `age` unchanged and warns. The clamp never worked. Fix: `update_change(:age, &min(&1, 120))` in the changeset.

6. **`&&` and `!` on booleans (Use `and`, `or`, `not`).** `is_binary(email) && age >= 18` and `opts[:notify] && !opts[:silent]`. The first check is also dead code, since `String.downcase/1` already raised on a non-binary. Fix: `validate_number(:age, greater_than_or_equal_to: 18)`, and a single `notify` option (see 7).

7. **Overlapping booleans (one atom-valued option).** `notify: true, silent: true` contradict each other. Fix: keep `:notify` only, and validate with `Keyword.validate!/2`.

8. **Option changes the return shape (one return shape).** `return_id: true` returns a bare id instead of `{:ok, user}`. Fix: remove the option; callers read `user.id`.

9. **Catch-all error clauses (Match every expected shape).** `_ -> {:error, :insert_failed}` and the repeated `{:error, :invalid}` discard the reason. Fix: return `{:error, changeset}` and let the caller see which field failed.

10. **Nested `if`/`case`/`if` and a long function (Keep functions short).** `import_user/2` is one block four levels deep. Fix: public function reads as build, insert, notify; helpers sit below.

11. **Bare `spawn/1` (processes.md: supervise long-lived processes).** An unsupervised process whose failure goes unseen. It also copies the whole `user` struct, which it needs anyway for the email. Fix: `Task.Supervisor.start_child/2` under an `Accounts.TaskSupervisor` that the application supervision tree must start.

12. **`user[:name]` on a struct (Read required keys with `map.key`).** Structs do not implement `Access`, so this raises `UndefinedFunctionError`. Fix: dot access. `User` has no known `name` field here, so I used `nickname`; change it if the schema has `name`.

13. **Pipe into an anonymous function (Pipelines).** `greeting |> (fn text -> ... end).()` and the intermediate string. Fix: one interpolated string.

14. **Comments and docs.** `# Import a single user from the given params`, `# Get the role from params`, `# send the email` restate the code. The module and function docs are comments. Fix: `@moduledoc`, `@doc` with `## Options` and examples; keep the comment about the provider lowercasing emails, since it gives a reason the code cannot show.

15. **Import order and magic numbers.** `120` and `18` become `@max_age` and `@min_age`. Alias stays at the top.

Behavior changes to be aware of: a duplicate email now returns `{:error, changeset}` instead of `{:error, :invalid}`; `return_id` and `silent` are gone; the age clamp to 120 now works.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV/JSON source.
  """

  alias Accounts.Mailer
  alias Accounts.Repo
  alias Accounts.User

  @doc """
  Imports a single user from string-keyed params.

  Returns `{:ok, user}`, or `{:error, changeset}` when the params are
  invalid or the email is already taken.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

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
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

Supporting changeset in `Accounts.User` (with `field :role, Ecto.Enum, values: [...]`, `defstruct`-style schema fields `email`, `age`, `nickname`, and a unique index on `email`):

```elixir
@min_age 18
@max_age 120

def import_changeset(user, params) do
  user
  |> cast(params, [:email, :age, :role, :nickname])
  |> validate_required([:email, :age, :role])
  # The provider lowercases addresses before its uniqueness check, so match it here
  |> update_change(:email, &String.downcase/1)
  |> update_change(:age, &min(&1, @max_age))
  |> validate_number(:age, greater_than_or_equal_to: @min_age)
  |> put_default_nickname()
  |> unique_constraint(:email)
end

defp put_default_nickname(changeset) do
  case get_field(changeset, :nickname) do
    nil -> put_change(changeset, :nickname, get_field(changeset, :email))
    _nickname -> changeset
  end
end
```

Not compiled or run: no Mix project, `Accounts.User`, `Mailer` or `TaskSupervisor` exist in this sandbox.
