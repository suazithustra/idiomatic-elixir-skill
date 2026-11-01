# Review: `Accounts.UserImporter`

Checked against `SKILL.md`, `references/processes.md`, and `references/ecto-phoenix.md`. The module has a wrong result, a crash path, and an atom leak, which are the first three findings. The rest are style and design rules.

## Findings

1. The age cap never runs. Line 15 to 17 sets `age = 120` inside an `if`, and a variable set inside `if` does not change the variable outside it. An age of 150 is stored as 150. Fix: cap the age in the changeset with `update_change(:age, &min(&1, 120))`. Rule: SKILL.md, "Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it".

2. Line 8 calls `String.to_atom/1` on the `role` value from the input file. Atoms are never removed from memory, so a bad file can fill the atom table and crash the node. A missing role also crashes here, before the `try`. Fix: declare `role` as `Ecto.Enum` in the schema, so the changeset maps the listed strings to atoms and rejects the rest. Rule: SKILL.md, "Convert external strings to atoms with explicit clauses".

3. Line 10 and 42 to 43 wrap the whole function in `try` with `rescue _ ->`. That turns every error into `{:error, :invalid}`, including a lost database connection. Line 13 uses `String.to_integer/1`, which raises on bad input, and the blanket `rescue` is what hides that raise. Fix: remove the `try`, and let the changeset cast `age` and report a bad value as a changeset error. Rule: SKILL.md, "Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs".

4. Lines 12, 21, 22, and 25 build a `%User{}` from the params by hand, check the fields with `if`, and pass the struct to `Repo.insert/1`. Nothing is validated that way, and a constraint violation raises. Line 12 also pipes a single step, `params["email"] |> String.downcase()`. Fix: build the record with `User.changeset/2`, which casts, validates, and normalizes the email. Rule: references/ecto-phoenix.md, "Validate input with changesets".

5. Line 24 runs `Repo.get_by(User, email: email) == nil` before the insert. Two imports of the same email can both pass that check, and the second insert then fails with a database error. Fix: declare `unique_constraint(:email)` in the changeset and let the insert report the conflict as `{:error, changeset}`. This needs a unique index on the email column. Rule: references/ecto-phoenix.md, "Declare database constraints in the changeset".

6. Lines 33 and 34 use `_ ->` after `{:ok, user}`, so every other result, including future ones, becomes `{:error, :insert_failed}` and the cause is lost. Fix: pass `{:error, changeset}` through unchanged with a `with`. Rule: SKILL.md, "Match every expected shape and let unexpected ones crash".

7. Line 31 returns a bare ID when the `:return_id` option is set and `{:ok, user}` otherwise. A caller cannot write one pattern for both. Fix: remove the option and return `{:ok, user}` always; callers read `user.id`. Rule: SKILL.md, "Give each function one return shape".

8. Line 27 has the options `:notify` and `:silent`. `notify: true, silent: true` makes no sense, so the two overlap. Fix: remove `:silent`, which the code never needs once `:notify` is the only switch. Rule: SKILL.md, "Use one atom-valued field or option instead of overlapping booleans". If callers pass `silent: true` today, they need to change; that is the one change to the public API.

9. Lines 15 to 41 nest three levels deep: `if`, `if`, `case`, and `if`. Line 21 also joins two booleans with `&&`. Fix: a one-step `with` that passes the insert result through, with the welcome email sent in the success branch. Changeset validation takes the place of the nested checks. Rule: SKILL.md, "Chain fallible steps with `with`; normalize each step's error in a small private function".

10. Line 49 starts the email with a bare `spawn/1`. Nothing supervises that process, so a crash is lost and the process does not show up in monitoring tools. The closure also captures the whole `user`, where only the greeting text is needed. Fix: start the work under a `Task.Supervisor` and capture only the greeting. Rule: references/processes.md, "Supervise every long-lived process".

11. Line 53 reads `user[:name]`. Structs do not implement `Access`, so this raises `UndefinedFunctionError`. The `User` struct also has no `name` field, so the greeting should use `nickname`, which the import always sets. Fix: `user.nickname`. Rule: SKILL.md, "Read required keys with `map.key` or a pattern; keep `map[:key]` for optional keys".

12. Lines 54 and 55 build the greeting with `<>` and then pipe it into an anonymous function, `(fn text -> ... end).()`. Fix: one string with interpolation. Rule: SKILL.md, "Do not pipe into an anonymous function call".

13. Comments on lines 2, 5, 7, and 48 restate the code, and the import function has no `@doc`. Fix: move the module description into `@moduledoc` and the function description and options into `@doc`, and delete the restating comments. Keep the comment on line 11, since it gives the reason for the downcase, and move it next to the `update_change` line in `Accounts.User`. Rule: SKILL.md, "Comments explain why; documentation goes in `@moduledoc` and `@doc`".

## Improved code

`lib/accounts/user_importer.ex`:

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.{Repo, User}

  @doc """
  Imports a single user from the given params.

  Returns `{:ok, user}`, or `{:error, changeset}` when the params fail
  validation or the email is already taken.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    params = Map.put(params, "nickname", params["nickname"] || params["email"])

    with {:ok, user} <- Repo.insert(User.changeset(%User{}, params)) do
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

`lib/accounts/user.ex`, the changeset the importer calls:

```elixir
defmodule Accounts.User do
  use Ecto.Schema

  import Ecto.Changeset

  schema "users" do
    field(:email, :string)
    field(:age, :integer)
    field(:nickname, :string)
    field(:role, Ecto.Enum, values: [:admin, :editor, :member])

    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :age, :nickname, :role])
    |> validate_required([:email, :age, :role])
    # The provider lowercases addresses before its uniqueness check, so match it here
    |> update_change(:email, &String.downcase/1)
    |> validate_number(:age, greater_than_or_equal_to: 18)
    |> update_change(:age, &min(&1, 120))
    |> unique_constraint(:email)
  end
end
```

Both files pass `mix format --check-formatted`. They do not compile here, because `Accounts.Repo`, the Ecto dependency, and the mailer are not in this project.

## What changes for callers

- Failed imports return `{:error, changeset}`, not `{:error, :invalid}` or `{:error, :insert_failed}`. Callers that matched those atoms must match the changeset instead.
- The `:silent` and `:return_id` options are gone.
- The `role` values `:admin`, `:editor`, and `:member` are placeholders. Replace them with the roles the real `User` schema uses.
- The code needs a unique index on `users.email` and an `Accounts.TaskSupervisor` in the application's supervision tree.
- A missing nickname now defaults to the email as typed. The old code used the lowercased email.
