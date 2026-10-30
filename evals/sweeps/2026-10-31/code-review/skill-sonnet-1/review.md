# Review: `Accounts.UserImporter`

Files read first: `SKILL.md`, `references/processes.md` (the module uses `spawn`), `references/ecto-phoenix.md` (it uses `Repo` and a schema).

## Findings

1. **Atom leak from user input.** Rule: convert external strings to atoms with explicit clauses. `role = String.to_atom(params["role"])` lets anyone who controls the input exhaust the atom table and crash the node. It also raises on a missing role. Fix: cast `role` through an `Ecto.Enum` field in the changeset, so only listed values are accepted.

2. **Whole function wrapped in `try/rescue _ ->`.** Rule: return tuples for expected failures; never `rescue _`. It hides real bugs (for example a `Mailer` typo) as `{:error, :invalid}`. Fix: remove the `try`. Use `Integer.parse/1` for age, a head pattern for required keys, and a changeset for the rest.

3. **`age = 120` inside `if` has no effect.** Rule: rebinding inside a block does not escape it. `if age > 120 do age = 120 end` leaves `age` unchanged, so the cap never applies, and the compiler warns. Fix: `min(age, 120)`.

4. **Hand-built `%User{}` passed to `Repo.insert/1`.** Rule (ecto-phoenix): validate input with changesets. Nothing is validated, and `age >= 18` and the email check are done by hand. Fix: `User.changeset/2` with `validate_number/3` and `Ecto.Enum`.

5. **Lookup before insert** (`Repo.get_by(User, email: email) == nil`). Rule: declare `unique_constraint/3`. Two concurrent imports of the same email both pass the check and one raises (swallowed by the `rescue` as `:invalid`). Fix: `unique_constraint(:email)` in the changeset; the insert returns `{:error, changeset}`. This needs a unique index on `users.email`.

6. **`_ ->` clause after `{:ok, user}`.** Rule: match every expected shape. It turns the changeset error into `:insert_failed` and discards the reason. Fix: pass `{:error, changeset}` through (the `with` does this).

7. **`&&` and `!` on non-booleans, and overlapping booleans.** Rules: use `and`/`not` for booleans; use one option instead of overlapping booleans. `is_binary(email) && age >= 18` and `opts[:notify] && !opts[:silent]`. `is_binary(email)` also runs after `String.downcase/1` has already raised on a non-binary. Fix: `when is_binary(email)` in the head; a single `notify: true` option, checked with `Keyword.validate!/2`.

8. **`:return_id` changes the return shape.** Rule: one return shape per function. It returns either `user.id` or `{:ok, user}`. Fix: always `{:ok, user}`; callers read `user.id`.

9. **`user[:name]` on a struct.** Rule: structs do not implement `Access`. `user[:name]` raises `UndefinedFunctionError`, inside a spawned process, so the email silently never sends. Fix: `user.nickname`. The importer never sets `name`, so I assumed `User` has no `:name` field. Change this if it does.

10. **Bare `spawn/1`.** Rule (processes): supervise processes; send only the data needed. Mail failures are unsupervised and invisible, and the closure copies the whole `user`. Fix: `Task.Supervisor.start_child(Accounts.TaskSupervisor, ...)`. This assumes `{Task.Supervisor, name: Accounts.TaskSupervisor}` is in the application's supervision tree. `Mailer` is not aliased in this module; I could not tell its full name, so I left it as written.

11. **Pipe into an anonymous function** (`greeting |> (fn text -> ... end).()`) and a pipeline of a single step (`params["email"] |> String.downcase()`). Fix: build the string with interpolation; call `String.downcase(email)`.

12. **`params["email"]`, `["age"]`, `["role"]` read as optional keys.** Rule: match required string keys in the head with a catch-all clause. A missing key surfaced as an exception caught by `rescue`. Fix: head pattern plus `def import_user(_params, _opts), do: {:error, :invalid_params}`. `nickname` is genuinely optional and keeps `params["nickname"]`.

13. **Comments that restate code, no docs.** Rule: comments explain why; use `@moduledoc`/`@doc`. Removed `# Get the role from params`, `# send the email`, and the header comments. Kept the comment about the provider lowercasing addresses, since it gives a reason. Added `@moduledoc` and `@doc` with an `## Options` section. No doctest `## Examples`, because every example needs a database.

14. **Nested `if`/`case`/`if`, four levels deep.** Rule: keep functions short, one level of detail. Fix: `with` chain plus small private functions (`parse_age/1`, `insert_user/2`, `maybe_notify/2`).

15. **Alias order and grouping.** Minor: `alias` is fine after `@moduledoc`; kept.

## Behavior changes to be aware of

- Error values change from `:invalid` / `:insert_failed` to `{:error, :invalid_params}`, `{:error, {:invalid_field, "age"}}`, or `{:error, %Ecto.Changeset{}}`. Callers that match on the old atoms need updating.
- `return_id:` and `silent:` options are removed.
- Under-18 users, duplicate emails and unknown roles now return a changeset error instead of `:invalid`.

## Companion change in `Accounts.User`

The importer relies on a changeset like this (I could not see the schema, so adjust field names and the role values):

```elixir
@roles [:member, :admin]

schema "users" do
  field :email, :string
  field :age, :integer
  field :nickname, :string
  field :role, Ecto.Enum, values: @roles
end

def changeset(user, attrs) do
  user
  |> cast(attrs, [:email, :age, :nickname, :role])
  |> validate_required([:email, :age, :role])
  |> validate_number(:age, greater_than_or_equal_to: 18)
  |> unique_constraint(:email)
end
```

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV/JSON source.
  """

  alias Accounts.{Repo, User}

  @max_age 120

  @doc """
  Imports a single user from string-keyed params.

  Requires the `"email"`, `"age"` and `"role"` keys. `"nickname"` is optional
  and defaults to the email.

  Returns `{:ok, user}`, `{:error, :invalid_params}` when a required key is
  missing, `{:error, {:invalid_field, "age"}}` when the age is not a number, or
  `{:error, changeset}` when validation or the unique email constraint fails.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ [])

  def import_user(%{"email" => email, "age" => age, "role" => role} = params, opts)
      when is_binary(email) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, age} <- parse_age(age),
         {:ok, user} <- insert_user(params, age) do
      maybe_notify(user, opts[:notify])
      {:ok, user}
    end
  end

  def import_user(_params, _opts), do: {:error, :invalid_params}

  defp parse_age(age) when is_integer(age), do: {:ok, min(age, @max_age)}

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {age, ""} ->
        {:ok, min(age, @max_age)}

      _other ->
        {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(_age), do: {:error, {:invalid_field, "age"}}

  defp insert_user(params, age) do
    # The provider lowercases addresses before its uniqueness check, so match it here
    email = String.downcase(params["email"])

    attrs = %{
      "email" => email,
      "age" => age,
      "role" => params["role"],
      "nickname" => params["nickname"] || email
    }

    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp maybe_notify(user, true), do: send_welcome(user)
  defp maybe_notify(_user, false), do: :ok

  defp send_welcome(user) do
    email = welcome_email(user)

    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

Not run: no `mix format` or compile check was done, since the module depends on `Accounts.Repo`, `Accounts.User` and `Mailer`, which are not in this file.
