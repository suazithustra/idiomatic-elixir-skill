# Review: `Accounts.UserImporter`

Code I could not see (the `User` schema, `Mailer`, the task supervisor) is assumed; the assumptions are listed at the end. I did not compile or run the improved code (no Mix project here).

## Findings

1. **Atom leak from user input.** Rule: convert external strings to atoms with explicit clauses. Line: `role = String.to_atom(params["role"])`. Anyone who controls `role` can exhaust the atom table and crash the node. Fix: `parse_role/1` with one clause per accepted role and an `{:error, {:unknown_role, other}}` clause.

2. **`try/rescue _ ->` around the whole function.** Rule: return tuples for expected failures; never `rescue _`. Line: `rescue _ -> {:error, :invalid}`. A missing `"email"`, a non-numeric `"age"` and a real bug in `Repo` or `Mailer` all become `:invalid`. Fix: remove the `try`; use `Integer.parse/1` (the non-raising parser) and match the required keys in the function head.

3. **Rebinding inside `if` has no effect.** Rule: assign the result of `if`. Line: `if age > 120 do age = 120 end`. The outer `age` is never capped, and the compiler warns about an unused variable. Fix: `min(age, @max_age)` in `parse_age/1`, with the magic number named.

4. **No changeset; lookup before insert.** Rule: validate input with changesets; `unique_constraint/3` instead of a hand-built check. Lines: `%User{email: ..., age: ...}`, `Repo.get_by(User, email: email) == nil`, `Repo.insert(user)`. The struct is inserted unvalidated. The lookup-then-insert is a race: two imports of the same email can both pass the check, and the second insert then raises. Fix: `User.changeset/2` with `validate_required`, `validate_number` (age at least 18) and `unique_constraint(:email)`; a duplicate returns `{:error, changeset}`.

5. **Catch-all `_ ->` and one error reason for everything.** Rule: match every expected shape; distinct failures get distinct reasons. Lines: `_ -> {:error, :insert_failed}`, `{:error, :invalid}` (three places). The changeset errors are thrown away. Fix: `with` passes `{:error, changeset}` and the `{:invalid_field, ...}` / `{:unknown_role, ...}` reasons through unchanged.

6. **`&&` and `!` on booleans.** Rule: `and`/`or`/`not` for booleans. Line: `is_binary(email) && age >= 18`. The `is_binary(email)` test also comes after `String.downcase(email)`, which has already raised for a non-binary. Fix: `is_binary(email)` becomes a guard on the head; the age check moves to the changeset.

7. **Overlapping boolean options.** Rule: one atom-valued option instead of overlapping booleans. Line: `opts[:notify] && !opts[:silent]`. Fix: a single `:notify` option, checked with `Keyword.validate!/2` so a misspelled option raises.

8. **Option changes the return shape.** Rule: one return shape per function. Line: `if opts[:return_id], do: user.id, else: {:ok, user}`. Fix: removed. Callers who want the ID use `{:ok, user}` and read `user.id`.

9. **Unsupervised `spawn` that copies the whole struct.** Rule (processes reference): supervise long-lived processes; send processes only the data they need. Line: `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`. A crash in `Mailer` is invisible and the work is not stopped on shutdown. Fix: `Task.Supervisor.start_child/2`; the email is built before the closure, so only the email is copied.

10. **`user[:name]` on a struct.** Rule: structs do not implement `Access`. Line: `name = user[:name] || "there"`. This raises `UndefinedFunctionError`. The importer also never sets `:name`. Fix: read `user.nickname`, which the importer always sets.

11. **Pipe into an anonymous function, and a one-step pipe.** Rule: no `|> (fn ... end).()`; do not pipe a single step. Lines: `greeting |> (fn text -> ... end).()`, `params["email"] |> String.downcase()`. Fix: one interpolated string; `String.downcase(email)`.

12. **`params["email"]` on required keys.** Rule: read required keys with a pattern. Fix: `import_user/2` matches `"email"`, `"age"` and `"role"` in its head; a second clause returns `{:error, :invalid_params}` (it does not guess which key is missing).

13. **Comments restate code; no docs.** Rule: comments explain why; use `@moduledoc`/`@doc`. Lines: `# Get the role from params`, `# send the email`, `# Import a single user...`. Kept the one comment that gives a reason (the lowercasing) and moved it to the function that does it.

14. **Aliases.** `alias Accounts.{Repo, User}` is fine but `Mailer` was used without an alias. Added one alias per line.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV/JSON source.
  """

  alias Accounts.Mailer
  alias Accounts.Repo
  alias Accounts.User

  @max_age 120

  @doc """
  Imports a single user from string-keyed `params`.

  `params` must hold `"email"`, `"age"` and `"role"`; `"nickname"` is optional
  and defaults to the email. Ages above #{@max_age} are stored as #{@max_age}.

  Returns `{:ok, user}`, `{:error, changeset}` when validation fails or the
  email is already taken, `{:error, {:invalid_field, field}}` or
  `{:error, {:unknown_role, role}}` for input that cannot be parsed, and
  `{:error, :invalid_params}` when a required key is missing.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ [])

  def import_user(%{"email" => email, "age" => age, "role" => role} = params, opts)
      when is_binary(email) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, age} <- parse_age(age),
         {:ok, role} <- parse_role(role),
         {:ok, user} <- insert_user(build_attrs(params, email, age, role)) do
      if Keyword.fetch!(opts, :notify), do: send_welcome(user)
      {:ok, user}
    end
  end

  def import_user(_params, _opts), do: {:error, :invalid_params}

  defp build_attrs(params, email, age, role) do
    # The provider lowercases addresses before its uniqueness check, so match it here
    email = String.downcase(email)

    %{
      email: email,
      age: age,
      role: role,
      nickname: params["nickname"] || email
    }
  end

  defp insert_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {age, ""} ->
        {:ok, min(age, @max_age)}

      _invalid ->
        {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(_age), do: {:error, {:invalid_field, "age"}}

  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("editor"), do: {:ok, :editor}
  defp parse_role("member"), do: {:ok, :member}
  defp parse_role(other), do: {:error, {:unknown_role, other}}

  defp send_welcome(user) do
    email = welcome_email(user)

    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

Changeset the importer now relies on, in `Accounts.User`:

```elixir
def changeset(user, attrs) do
  user
  |> cast(attrs, [:email, :age, :role, :nickname])
  |> validate_required([:email, :age, :role])
  |> validate_number(:age, greater_than_or_equal_to: 18)
  |> unique_constraint(:email)
end
```

## Assumptions

- `User.role` is an `Ecto.Enum` (or a plain atom field) with the values `:admin`, `:editor`, `:member`. Replace the `parse_role/1` rows with the real list.
- `Accounts.TaskSupervisor` is started in the application's supervision tree, and the `email` column has a unique index.
- `user.nickname` stands in for the unset `user[:name]` in the greeting. If `User` has a `:name` field that is filled elsewhere, use it instead. The old "there" fallback is gone because the nickname always exists.
- `Mailer.deliver/1` accepts the greeting string, as it did before.
- Behavior changes: unknown or malformed input now returns specific errors instead of `:invalid`; a duplicate email returns `{:error, changeset}` instead of `{:error, :invalid}`; `:silent` and `:return_id` options no longer exist; ages above 120 are now actually capped.
