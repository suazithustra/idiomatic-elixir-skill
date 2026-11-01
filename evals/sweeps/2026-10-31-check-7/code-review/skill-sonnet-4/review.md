# Review: `Accounts.UserImporter`

Rules come from the idiomatic-elixir skill, plus `references/processes.md` (for `spawn`) and `references/ecto-phoenix.md` (for `Repo`).

## Findings

1. **`String.to_atom/1` on input** (`role = String.to_atom(params["role"])`). Anyone who controls `params["role"]` can exhaust the atom table (atoms are never garbage-collected) and crash the node. A missing role also raises. Rule: convert external strings to atoms with explicit clauses. Fix: make `role` an `Ecto.Enum` field and let `cast/3` accept only the listed values. An unknown role then comes back as a changeset error.

2. **`try/rescue` with `rescue _ ->` around the whole function.** It turns bugs (`nil` email, `nil` age, a failed insert) and expected failures into the same `{:error, :invalid}`. Rule: use the non-raising version, and never rescue `_` around a whole function. Fix: `Integer.parse/1` and `with`, with a separate reason for each failure.

3. **`String.to_integer(params["age"])` and `params["email"] |> String.downcase()`** read required keys with `params["key"]` and then crash on `nil`. Rules: match required string-keyed input in the function head, with a separate clause for no match; read required keys without `nil` surprises. Fix: match `"email"`, `"age"` and `"role"` in the head, with `{:error, :invalid_params}` as the last clause. The age is parsed in `parse_age/1`, which returns `{:error, {:invalid_field, "age"}}`.

4. **`if age > 120 do age = 120 end`.** A rebinding inside `if` does not escape the block, so the age is never capped, and the compiler warns. Rule: assign the result of `if`. Fix: `min(age, @max_age)`, and the cap is a named module attribute (`@max_age`).

5. **`if is_binary(email) && age >= 18`.** Two problems. `&&` is used on booleans (rule: use `and`). And `is_binary(email)` runs after `String.downcase(email)` already raised for a non-binary, so it never checks anything. Fix: `is_binary(email)` is a guard in the head, and `age >= 18` moves into the changeset as `validate_number/3`.

6. **`%User{...}` passed to `Repo.insert/1` with no changeset.** Nothing is validated and a constraint violation raises. Rule (ecto-phoenix): cast and validate with a changeset. Fix: `User.changeset/2` (proposed below).

7. **`Repo.get_by(User, email: email) == nil` before the insert.** This is a check-then-insert race: two imports of the same address can both pass the check, and the second insert raises or creates a duplicate. It builds by hand what `unique_constraint/3` does. Fix: declare `unique_constraint(:email)` in the changeset and let the insert return `{:error, changeset}`.

8. **`_ -> {:error, :insert_failed}`** drops the changeset and would hide any new return shape. Rule: match every expected shape. Fix: the insert result goes out as `{:error, changeset}`, so the caller can see which field failed.

9. **`opts[:notify] && !opts[:silent]`**: two overlapping booleans (`notify: true, silent: true` is meaningless), `!` on values that may be `nil`, and no option validation. Fix: a single `:notify` option, checked with `Keyword.validate!/2` and documented under `## Options`. If `:silent` has callers, they need a migration, so this is an API change.

10. **`opts[:return_id]` changes the return shape** (`user.id` or `{:ok, user}`). Rule: one return shape per function. Fix: drop the option; callers who want the ID read `user.id`. This is an API change.

11. **Nested `case` inside `if` inside `if` inside `try`.** Rule: keep functions short and at one level of detail. Fix: `import_user/2` is a short `with`; `insert_user/1`, `parse_age/1` and `maybe_send_welcome/2` hold the details.

12. **`spawn(fn -> Mailer.deliver(...) end)`.** The process is unsupervised, so a crash is silent and shutdown cannot wait for it. Rule (processes): fire-and-forget work uses `Task.Supervisor.start_child/2`. Fix: `Task.Supervisor.start_child(Accounts.TaskSupervisor, ...)`. This needs `{Task.Supervisor, name: Accounts.TaskSupervisor}` in the application's supervision tree.

13. **`user[:name]`** on a `%User{}`. Structs do not implement `Access`, so this raises `UndefinedFunctionError`, and the `|| "there"` default is never reached. `%User{}` here has no `:name` field. Fix: use `user.nickname`, which `import_user` always sets. If a `name` field exists, use `user.name` instead.

14. **`greeting |> (fn text -> ... end).()`** pipes into an anonymous function, and the string is built in three steps. Rule: do not pipe into an anonymous function. Fix: one interpolated string.

15. **Comments that restate the code** (`# Get the role from params`, `# send the email`, `# Import a single user ...`), and documentation as comments. Rule: comments explain why; documentation goes in `@moduledoc`/`@doc`. Fix: `@moduledoc` and `@doc` with `## Options`, and the comment about the provider lowercasing addresses is kept because it gives a reason. `@doc` and `@spec` are added for the public function.

16. **`Mailer` is not aliased and not under the `Accounts` namespace.** I assumed `Accounts.Mailer`. Check this against the project.

## Assumptions to check

- `Accounts.User` is an Ecto schema with an `Ecto.Enum` `role` field. Its allowed values below (`:admin`, `:editor`, `:member`) are guesses; use the real ones.
- `users.email` has a unique index. Without one, `unique_constraint/3` does nothing.
- Behavior change: the original capped ages above 120 (it tried to, and failed because of finding 4). The fix keeps the cap rather than rejecting.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV/JSON source.
  """

  alias Accounts.{Mailer, Repo, User}

  @max_age 120

  @doc """
  Imports a single user from string-keyed params.

  Requires the `"email"`, `"age"` and `"role"` keys; `"nickname"` is optional
  and defaults to the email. Ages above #{@max_age} are capped at #{@max_age}.

  Returns `{:ok, user}`, `{:error, :invalid_params}` when a required key is
  missing, `{:error, {:invalid_field, "age"}}` for an age that is not an
  integer, or `{:error, changeset}` when validation or the unique email
  constraint fails.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, term()}
  def import_user(params, opts \\ [])

  def import_user(%{"email" => email, "age" => age, "role" => role} = params, opts)
      when is_binary(email) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, age} <- parse_age(age),
         {:ok, user} <- insert_user(params, email, age, role) do
      maybe_send_welcome(user, opts[:notify])
      {:ok, user}
    end
  end

  def import_user(_params, _opts), do: {:error, :invalid_params}

  defp parse_age(age) when is_integer(age), do: {:ok, min(age, @max_age)}

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {age, ""} ->
        {:ok, min(age, @max_age)}

      _invalid ->
        {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(_age), do: {:error, {:invalid_field, "age"}}

  defp insert_user(params, email, age, role) do
    attrs = %{
      # The provider lowercases addresses before its uniqueness check, so match it here
      email: String.downcase(email),
      age: age,
      role: role,
      nickname: params["nickname"]
    }

    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp maybe_send_welcome(user, true), do: send_welcome(user)
  defp maybe_send_welcome(_user, false), do: :ok

  defp send_welcome(user) do
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn ->
      Mailer.deliver(welcome_email(user))
    end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

### Proposed `Accounts.User.changeset/2`

The importer relies on this. Adjust it to the real schema.

```elixir
schema "users" do
  field :email, :string
  field :age, :integer
  field :role, Ecto.Enum, values: [:admin, :editor, :member]
  field :nickname, :string
end

def changeset(user, attrs) do
  user
  |> cast(attrs, [:email, :age, :role, :nickname])
  |> validate_required([:email, :age, :role])
  |> validate_number(:age, greater_than_or_equal_to: 18)
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

Not run: no Elixir project or `User` schema was available, so the code was not compiled or formatted.
