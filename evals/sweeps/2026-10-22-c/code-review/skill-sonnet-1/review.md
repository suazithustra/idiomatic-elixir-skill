# Review: `Accounts.UserImporter`

## Findings

1. **Unvalidated struct inserted (ecto-phoenix: changesets).** `user = %User{email: email, age: age, role: role, nickname: nickname}` then `Repo.insert(user)`. Nothing is validated, and a constraint violation raises. Fix: `User.changeset/2` with `cast`, `validate_required`, `validate_number`, and `Ecto.Enum` for `role`.
2. **Hand-built uniqueness check (changeset rule).** `if Repo.get_by(User, email: email) == nil do` is a lookup before an insert, so it races. Fix: `unique_constraint(:email)` in the changeset, so the insert returns `{:error, changeset}`.
3. **`String.to_atom(params["role"])` (atoms rule).** External input can exhaust the atom table, and a missing role crashes. Fix: `role` is an `Ecto.Enum`, so `cast` accepts only the listed values.
4. **`try ... rescue _ -> {:error, :invalid}` around the whole function (errors rule).** It hides bugs, such as the failure from `String.downcase(nil)`, behind `:invalid`. Fix: remove it. Validation returns `{:error, changeset}`.
5. **`String.to_integer(params["age"])` (non-raising version rule).** It raises on bad input. Fix: Ecto's `cast` of `:age` as an integer.
6. **`if age > 120 do age = 120 end` (rebinding rule).** The rebind is local to the `if`, so the clamp never happens, and the compiler warns. Fix: `update_change(:age, &min(&1, @max_age))`, with the magic number named.
7. **`is_binary(email) && age >= 18` after `String.downcase`.** The `is_binary` check can never fail because `downcase` has already raised, and `&&` is used on booleans (`and` rule). `!opts[:silent]` has the same issue. Fix: validation in the changeset, and `and`/`not` for booleans.
8. **Overlapping booleans `notify`/`silent` (one atom option rule).** `notify: true, silent: true` is meaningless. Fix: keep only `:notify`, validated with `Keyword.validate!/2` and documented under `## Options`.
9. **Option changes return shape (`return_id` gives `user.id` or `{:ok, user}`).** Fix: remove the option. Callers use `user.id`.
10. **Nested `if`/`case`/`if` and a `_ ->` clause.** The nesting is hard to follow, and `_ -> {:error, :insert_failed}` discards the real reason. Fix: a flat `case` that matches `{:error, %Ecto.Changeset{}}` explicitly, with the insert in a private function.
11. **`spawn/1` for the email (processes).** It is unsupervised fire-and-forget. Fix: `Task.Supervisor.start_child/2`, and the closure captures only the built email, not the whole user.
12. **`user[:name]` on a struct (data access).** Structs do not implement `Access`, so this raises `UndefinedFunctionError`. The struct has no `:name` field, so the greeting uses `user.nickname`.
13. **`|> (fn ... end).()` and a one-step pipe in `welcome_email/1`.** Fix: plain string interpolation.
14. **Comments that restate the code** (`# Get the role from params`, `# send the email`, `# Import a single user...`). They are deleted, and the one "why" comment (the provider lowercases emails) is kept. Docs move to `@moduledoc`/`@doc`, placed before `alias`.
15. **Error reasons.** `:invalid` for every failure loses the cause. Fix: return the changeset.

## Assumptions

- `Accounts.User` is an Ecto schema with `role` as `Ecto.Enum`, and the `changeset/2` below is added to it.
- `Mailer` is `Accounts.Mailer`, and `Accounts.TaskSupervisor` runs under the supervision tree.
- Ages over 120 are clamped, as the original intended, and ages under 18 are rejected.
- Not compiled: Ecto is not available in this environment.

## Improved code

```elixir
defmodule Accounts.User do
  # Only the changeset is shown; the schema is unchanged except for `role` as an Ecto.Enum.
  import Ecto.Changeset

  @min_age 18
  @max_age 120

  def changeset(user, params) do
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
end

defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV/JSON source.
  """

  alias Accounts.{Mailer, Repo, User}

  @doc """
  Imports a single user from string-keyed `params`.

  Returns `{:ok, user}`, or `{:error, changeset}` when the params are invalid
  or the email is already taken.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    case insert_user(params) do
      {:ok, user} ->
        if opts[:notify], do: send_welcome(user)

        {:ok, user}

      {:error, %Ecto.Changeset{}} = error ->
        error
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
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```
