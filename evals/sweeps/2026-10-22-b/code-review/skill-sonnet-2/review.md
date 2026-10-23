# Review: `Accounts.UserImporter`

Reference files read: `processes.md` (`spawn`), `ecto-phoenix.md` (`Repo`, `%User{}`).

## Findings

1. **Bug: rebinding inside `if` does not escape it** (rule: assign the result of `if`)
   `if age > 120 do age = 120 end` leaves `age` unchanged, so the cap never applies and the compiler warns. Fix: `age = min(age, @max_age)`.

2. **`String.to_atom/1` on external input** (rule: convert external strings to atoms with explicit clauses)
   `role = String.to_atom(params["role"])` lets callers exhaust the atom table. A missing `"role"` also raises `ArgumentError` outside the `try`. Fix: cast the role through `Ecto.Enum` in the changeset, so only declared roles are accepted.

3. **`try ... rescue _ ->` around the whole function** (rule: return tuples for expected failures; never `rescue _`)
   It hides real bugs, such as the `age` bug above, as `{:error, :invalid}`. It exists to catch `String.to_integer/1` and `String.downcase(nil)`. Fix: use `Integer.parse/1` and match the required keys, so bad input returns an error tuple and bugs crash.

4. **`%User{...}` passed straight to `Repo.insert/1`** (ecto-phoenix: validate input with changesets)
   Nothing is validated, and a duplicate email raises. Fix: `User.changeset/2` with `cast`, `validate_required`, `Ecto.Enum` for the role, and `unique_constraint(:email)`, so a violation returns `{:error, changeset}`.

5. **`_ -> {:error, :insert_failed}` swallows the changeset** (rule: match every expected shape)
   The caller cannot tell which field failed. Fix: pass `{:error, %Ecto.Changeset{}}` through unchanged.

6. **Reading params with `params["key"]` and no required-key checks** (rule: parse external data at the boundary)
   A missing field becomes a `nil` crash somewhere else. Fix: small functions chained with `with` that return `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}`.

7. **Return shape depends on an option** (rule: one return shape)
   `opts[:return_id]` switches between `user.id` and `{:ok, user}`. Fix: remove the option. Callers read `user.id` from `{:ok, user}`.

8. **Overlapping booleans `:notify` and `:silent`** (rule: one atom-valued field or option instead of overlapping booleans)
   `notify: true, silent: true` is meaningless. Fix: keep `:notify` only, validate it with `Keyword.validate!/2`, and document it under `## Options`.

9. **`&&` and `!` on booleans** (rule: `and`, `or`, `not` for booleans)
   `is_binary(email) && age >= 18` and `opts[:notify] && !opts[:silent]`. In the first, `is_binary(email)` is also always true after `String.downcase/1`, so it is a dead check. Fix: the age check becomes a function clause and `and` is no longer needed.

10. **Bare `spawn/1` with the whole `user` struct captured** (processes.md: supervise, send only what is needed)
    The fire-and-forget task is unsupervised, and the closure copies the whole struct. Fix: `Task.Supervisor.start_child/2` under a supervisor, and build the email before the closure so only the email is copied. This assumes `Accounts.TaskSupervisor` is in the application's supervision tree.

11. **`user[:name]` on a struct** (rule: structs do not implement `Access`)
    This raises `UndefinedFunctionError`. `User` has no `:name` field in this module, so the improved version uses `user.nickname`. Confirm that is the intended greeting.

12. **Piping into an anonymous function** (rule: pipelines)
    `greeting |> (fn text -> ... end).()`. Fix: one interpolated string.

13. **Comments that restate code, and missing docs** (rule: comments explain why)
    Delete `# Get the role from params`, `# send the email`, `# Import a single user ...`, and `# This module imports ...`. Keep the comment about the provider lowercasing, since it explains a reason. Add `@moduledoc`, `@doc` with `## Options`, and `@spec`.

14. **Magic number 120 and 18**
    Name them with module attributes.

15. **Unqualified `Mailer`** (rule: namespace modules under the app)
    It is outside the `Accounts` namespace. I left it alone because it is not defined in this file; confirm it is the real module name.

## Improved code

Assumes `Accounts.User.changeset/2` looks like:

```elixir
def changeset(user, attrs) do
  user
  |> cast(attrs, [:email, :age, :role, :nickname])
  |> validate_required([:email, :age, :role, :nickname])
  |> unique_constraint(:email)
end
```

with `field :role, Ecto.Enum, values: [...]` in the schema.

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV/JSON source.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from string-keyed `params`.

  Requires `"email"`, `"age"` and `"role"`; `"nickname"` defaults to the email.
  Ages above #{@max_age} are capped at #{@max_age}.

  Returns `{:ok, user}`, `{:error, {:missing_field, key}}`,
  `{:error, {:invalid_field, key}}`, or `{:error, changeset}`.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, term()}
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, email} <- required_string(params, "email"),
         {:ok, role} <- required_string(params, "role"),
         {:ok, age} <- parse_age(params),
         {:ok, user} <- insert_user(email, role, age, params["nickname"]) do
      if opts[:notify], do: send_welcome(user)

      {:ok, user}
    end
  end

  defp required_string(params, key) do
    case params do
      %{^key => value} when is_binary(value) -> {:ok, value}
      %{^key => _value} -> {:error, {:invalid_field, key}}
      %{} -> {:error, {:missing_field, key}}
    end
  end

  defp parse_age(%{"age" => age}) when is_binary(age) do
    case Integer.parse(age) do
      {age, ""} when age >= @min_age -> {:ok, min(age, @max_age)}
      {_age, ""} -> {:error, {:invalid_field, "age"}}
      {_age, _rest} -> {:error, {:invalid_field, "age"}}
      :error -> {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(%{"age" => _age}), do: {:error, {:invalid_field, "age"}}
  defp parse_age(%{}), do: {:error, {:missing_field, "age"}}

  defp insert_user(email, role, age, nickname) do
    # The provider lowercases addresses before its uniqueness check, so match it here
    email = String.downcase(email)

    attrs = %{
      "email" => email,
      "age" => age,
      "role" => role,
      "nickname" => nickname || email
    }

    %User{}
    |> User.changeset(attrs)
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

Notes: `Mailer.deliver/1` is called with the string from `welcome_email/1`, as in the original. Not compiled: `Accounts.Repo`, `User`, and `Mailer` are not available here.
