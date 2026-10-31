# Review: `Accounts.UserImporter`

Assumptions: `User` has no `changeset/2` yet (one is given below), `role` is an `Ecto.Enum` with the values `admin` and `member` (replace with the real set), the app runs a `Task.Supervisor` named `Accounts.TaskSupervisor`, and `Mailer` lives at `Accounts.Mailer`. Not compiled or formatted: I did not run `mix`.

## Findings

1. **Atom from user input** (Convert external strings to atoms with explicit clauses). `role = String.to_atom(params["role"])`. Anyone who controls the input can exhaust the atom table, and a missing role raises. Fix: `parse_role/1` with one clause per accepted value and an error clause.

2. **`try/rescue` with `_ ->` around the whole function** (Return tuples for expected failures; rescue only specific exceptions). `rescue _ -> {:error, :invalid}` hides every bug as `:invalid`. It exists only to catch `String.to_integer/1` and `String.downcase(nil)`. Fix: `Integer.parse/1` returns a tagged error, and the function head requires the keys.

3. **Rebinding inside `if`** (Assign the result of `if`). `if age > 120 do age = 120 end` has no effect, because `age` stays unchanged outside the block. Fix: `min(age, @max_age)`.

4. **Hand-built validation and a lookup before insert** (Ecto: validate with changesets; `unique_constraint/3`). `%User{...}` goes straight to `Repo.insert/1` with no validation, `Repo.get_by(...) == nil` before the insert is a race (two imports of one email both pass, and the second then raises on the database constraint), and the age check is manual. Fix: `User.changeset/2` with `validate_number` and `unique_constraint(:email)`; a duplicate now returns `{:error, changeset}`.

5. **`_ ->` catch-all** (Match every expected shape). `_ -> {:error, :insert_failed}` throws away the changeset errors. Fix: pass `{:error, changeset}` through.

6. **Required keys read with `params["key"]`** (Read required keys with a pattern). `email`, `age` and `role` are matched in the head of `import_user/2`, with a catch-all clause returning `{:error, :invalid_params}`. `nickname` is optional and keeps `params["nickname"]`.

7. **`&&` and `!` on booleans, and overlapping booleans** (Use `and`/`not`; one atom-valued option). `is_binary(email) && age >= 18` becomes a changeset check. `opts[:notify] && !opts[:silent]` has a combination that makes no sense (`notify: true, silent: true`); only `:notify` is kept, checked with `Keyword.validate!/2` and documented.

8. **Option changes the return shape** (One return shape per function). `return_id: true` returns a bare id instead of `{:ok, user}`. Removed. A caller that wants the id reads `user.id`.

9. **Nested `if`/`case`/`if`** (`with`, short functions). The six levels of nesting become one `with` over `parse_role/1`, `parse_age/1` and `insert_user/1`.

10. **Unsupervised `spawn/1`** (Supervise every long-lived process). A crashed mail delivery goes unnoticed. Fix: `Task.Supervisor.start_child/2`.

11. **`user[:name]` on a struct** (Structs do not implement `Access`). It raises `UndefinedFunctionError`, so `welcome_email/1` always crashes. Fix: read `user.nickname`. The old `|| "there"` default is dropped because `nickname` is always set (it falls back to the email).

12. **Pipe into an anonymous function, and a one-step pipe** (Pipelines). `greeting |> (fn ... end).()` and `params["email"] |> String.downcase()` are replaced by plain string interpolation and `String.downcase(email)`.

13. **Comments and docs** (Comments explain why; `@moduledoc`/`@doc`). `# Get the role from params`, `# send the email` and similar comments restate the code and are deleted. The module comment and function comment become `@moduledoc` and `@doc`. The comment about the provider lowercasing addresses explains a reason, so it stays. The magic numbers 18 and 120 become module attributes.

14. **`alias` grouping**. `alias Accounts.{Repo, User}` is split into one alias per line, with `Mailer` added (it was used unaliased).

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
  Imports a single user from string-keyed params.

  Requires `"email"`, `"age"` and `"role"`; `"nickname"` is optional and
  defaults to the email. Ages above #{@max_age} are stored as #{@max_age}.

  Returns `{:ok, user}`, `{:error, changeset}` for invalid data or a duplicate
  email, `{:error, {:invalid_field, field}}` for a malformed age or role, or
  `{:error, :invalid_params}` when a required key is missing.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ [])

  def import_user(%{"email" => email, "age" => age, "role" => role} = params, opts)
      when is_binary(email) do
    opts = Keyword.validate!(opts, notify: false)

    # The provider lowercases addresses before its uniqueness check, so match it here
    email = String.downcase(email)

    with {:ok, age} <- parse_age(age),
         {:ok, role} <- parse_role(role),
         {:ok, user} <- insert_user(email, age, role, params["nickname"] || email) do
      if opts[:notify], do: send_welcome(user)

      {:ok, user}
    end
  end

  def import_user(_params, _opts), do: {:error, :invalid_params}

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {age, ""} ->
        {:ok, min(age, @max_age)}

      {_age, _rest} ->
        {:error, {:invalid_field, "age"}}

      :error ->
        {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(_age), do: {:error, {:invalid_field, "age"}}

  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("member"), do: {:ok, :member}
  defp parse_role(_role), do: {:error, {:invalid_field, "role"}}

  defp insert_user(email, age, role, nickname) do
    attrs = %{email: email, age: age, role: role, nickname: nickname}

    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

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

Add to `Accounts.User` (it replaces the manual age check and the `get_by` lookup):

```elixir
@min_age 18

def changeset(user, attrs) do
  user
  |> cast(attrs, [:email, :age, :role, :nickname])
  |> validate_required([:email, :age, :role, :nickname])
  |> validate_number(:age, greater_than_or_equal_to: @min_age)
  |> unique_constraint(:email)
end
```

`unique_constraint(:email)` needs a unique index on `users.email`; the lowercased address is what gets stored, so the index matches the provider's check.
