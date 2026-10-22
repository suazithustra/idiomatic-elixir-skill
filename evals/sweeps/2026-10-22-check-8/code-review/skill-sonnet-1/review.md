# Review of `Accounts.UserImporter`

## Findings

1. **Atom exhaustion (convert external strings to atoms with explicit clauses).**
   `role = String.to_atom(params["role"])`. Any caller can create atoms until the node crashes. A missing `"role"` also raises `ArgumentError` on `nil`. Fix: `role` is an `Ecto.Enum` field on `User`, so the changeset casts and validates it, and an unknown value becomes a changeset error.

2. **Rebinding inside `if` does not escape it (a real bug).**
   `if age > 120 do age = 120 end`. The age is never clamped, and the compiler warns that the inner `age` is unused. Fix: `min(age, @max_age)`.

3. **`try/rescue` used to get a tuple, with a catch-all `rescue _ ->`.**
   It hides every bug (for example `nil` from `params["email"]`) as `{:error, :invalid}`. Fix: non-raising `Integer.parse/1` and explicit `{:error, {:missing_field, key}}` / `{:error, {:invalid_field, key}}` reasons, with no `rescue`.

4. **`String.to_integer/1` and `String.downcase/1` on raw input.**
   Both raise on bad or missing input. The `is_binary(email)` check ran after `String.downcase` had already run, so it was dead. Fix: `string_field/2` checks the email is a binary before it is downcased, and `parse_age/1` accepts integers (JSON) or strings (CSV).

5. **Hand-built validation and a struct passed to `Repo.insert` (ecto-phoenix: validate with changesets).**
   `%User{...}` was inserted unvalidated, and the age check was done by hand. Fix: `User.changeset/2` with `cast`, `validate_required`, `validate_number(:age, greater_than_or_equal_to: 18)`, and `Ecto.Enum` for the role.

6. **Lookup before insert (`Repo.get_by(User, email: email) == nil`, then `Repo.insert`).**
   This is racy, and a concurrent insert raises at the database. Fix: `unique_constraint(:email)` in the changeset, so a duplicate returns `{:error, changeset}`. It needs a unique index on `email`.

7. **`_ ->` catch-all on `Repo.insert` and collapsed error reasons.**
   `:insert_failed` and `:invalid` discard the cause. Fix: pass `{:error, changeset}` through.

8. **Nested `if`/`case`/`if` in one long function.**
   Fix: a `with` chain of small steps (`build_attrs/1`, `insert_user/1`), each returning `{:ok, _}` or `{:error, _}`.

9. **`&&` and `!` on booleans.**
   `is_binary(email) && age >= 18` and `opts[:notify] && !opts[:silent]`. Fix: the checks moved into the changeset; the remaining option test is a single boolean.

10. **Overlapping booleans `notify:` / `silent:`.**
    `notify: true, silent: true` is meaningless. Fix: a single `:notify` option, validated with `Keyword.validate!/2`.

11. **An option changes the return shape (`return_id:` returns an id instead of `{:ok, user}`).**
    Fix: remove it. The function always returns `{:ok, user}` or `{:error, reason}`, and callers take `user.id`.

12. **Bare `spawn/1` for the email.**
    It is unsupervised, and the closure copies the whole `user`. Fix: `Task.Supervisor.start_child/2` under `Accounts.TaskSupervisor`, with the email built before the closure so only the email is copied. The supervisor must be in the application's children.

13. **`user[:name]` on a struct.**
    Structs don't implement `Access`, so this raises `UndefinedFunctionError`. Fix: `user.name`.

14. **Piping into an anonymous function.**
    `greeting |> (fn text -> ... end).()`. Fix: one interpolated string.

15. **Comments and docs.**
    Comments restate the code (`# Get the role from params`, `# send the email`), and the docs are comments rather than `@moduledoc` / `@doc`. Fix: delete the restating comments, keep the one that gives a reason (the provider lowercases emails), and add `@moduledoc`, `@doc` with `## Options`, and `@spec`.

16. **Magic number 120.**
    Fix: `@max_age` (and `@min_age` in the changeset).

17. **Alias placement.**
    The `alias` came after a comment instead of right after `@moduledoc`.

Assumptions: `User` has a `:name` field and an `Ecto.Enum` `:role` (the values below are placeholders), `Mailer` and `Accounts.TaskSupervisor` exist, and `users.email` has a unique index. I did not compile this because the project's dependencies (Ecto, `Mailer`) are not available here.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from external CSV/JSON params.
  """

  alias Accounts.Repo
  alias Accounts.User

  @max_age 120

  @doc """
  Imports a single user from string-keyed `params`.

  Returns `{:ok, user}`, `{:error, {:missing_field, key}}`,
  `{:error, {:invalid_field, key}}`, or `{:error, changeset}` when validation
  fails, including a duplicate email. Ages above 120 are clamped to 120.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, term()}
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, attrs} <- build_attrs(params),
         {:ok, user} <- insert_user(attrs) do
      if opts[:notify], do: send_welcome(user)

      {:ok, user}
    end
  end

  defp build_attrs(params) do
    with {:ok, email} <- string_field(params, "email"),
         {:ok, age} <- parse_age(params["age"]) do
      # The provider lowercases addresses before its uniqueness check, so match it here
      email = String.downcase(email)

      attrs = %{
        "email" => email,
        "age" => min(age, @max_age),
        "nickname" => params["nickname"] || email,
        "role" => params["role"]
      }

      {:ok, attrs}
    end
  end

  defp insert_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp string_field(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp parse_age(age) when is_integer(age), do: {:ok, age}
  defp parse_age(nil), do: {:error, {:missing_field, "age"}}

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {age, ""} -> {:ok, age}
      _other -> {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(_age), do: {:error, {:invalid_field, "age"}}

  defp send_welcome(user) do
    email = welcome_email(user)

    {:ok, _pid} =
      Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user) do
    name = user.name || "there"

    "Hi #{name}, welcome! Enjoy your account."
  end
end
```

Supporting change in `Accounts.User` (needed by findings 1, 5 and 6):

```elixir
@min_age 18

# in the schema
field :role, Ecto.Enum, values: [:admin, :editor, :member]

def changeset(user, attrs) do
  user
  |> cast(attrs, [:email, :age, :nickname, :role])
  |> validate_required([:email, :age, :role])
  |> validate_number(:age, greater_than_or_equal_to: @min_age)
  |> unique_constraint(:email)
end
```
