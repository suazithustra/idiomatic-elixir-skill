# Review: `Accounts.UserImporter`

Rules come from the idiomatic-elixir skill and its `processes.md`, `ecto-phoenix.md` and `library-design.md` references.

## Findings

1. **Convert external strings to atoms with explicit clauses.**
   `role = String.to_atom(params["role"])` turns request input into atoms. Atoms are never collected, so a caller can exhaust the atom table. It also raises on a missing role (`nil` is not a binary).
   Fix: `parse_role("admin")`, `parse_role("member")`, and `parse_role(other)` returning `{:error, {:unknown_role, other}}`.

2. **Don't wrap a raising call in `try/rescue` to get a tuple, and never `rescue _ ->`.**
   `rescue _ -> {:error, :invalid}` wraps the whole function. It turns every bug, such as a `Repo` failure, a typo, or a `FunctionClauseError`, into `:invalid`. `String.to_integer/1` and `String.downcase(nil)` are the calls it covers for.
   Fix: use `Integer.parse/1`, and match required fields in small functions. Remove the `try`.

3. **Rebinding inside `if` does not escape it.**
   `if age > 120 do age = 120 end` leaves `age` unchanged, and the compiler warns about an unused variable. The cap never applies.
   Fix: `age = min(age, @max_age)`.

4. **Use `and`/`not` with boolean operands.**
   `is_binary(email) && age >= 18` and `opts[:notify] && !opts[:silent]`. Also, `is_binary(email)` runs after `String.downcase(email)` has already raised for a non-binary, so the check is dead.
   Fix: validate the type first, then use `and`/`not`, or drop the check as below.

5. **Use one atom-valued option instead of overlapping booleans, and give each function one return shape.**
   `notify:` and `silent:` overlap (`notify: true, silent: true`). `return_id: true` changes the return from `{:ok, user}` to a bare `user.id`.
   Fix: keep `notify: boolean` (the only option), validated with `Keyword.validate!/2`. Drop `silent` and `return_id`; the caller reads `user.id` from `{:ok, user}`.

6. **Match every expected shape; don't use `_ ->`.**
   `_ -> {:error, :insert_failed}` throws away the changeset, so callers can't see why the insert failed.
   Fix: return the `{:error, changeset}` from `Repo.insert/1` unchanged.

7. **Use a changeset and `unique_constraint/3` instead of a lookup before an insert.**
   `Repo.get_by(User, email: email) == nil` followed by `Repo.insert(%User{...})` is a race: two imports can both pass the check, and the second insert then raises. It also inserts an unvalidated struct. Strings such as `:invalid` and `:insert_failed` hide the cause.
   Fix: pipe the params through `User.changeset/2`, which declares `unique_constraint(:email)`, and call `Repo.insert/1`. Set `role` on the struct before `cast/3` so params can't set it. This assumes the schema has a unique index on `email`.

8. **Return tagged error reasons, not one catch-all `:invalid`.**
   Three different failures (bad input, underage, duplicate) all return `{:error, :invalid}`.
   Fix: `{:error, {:missing_field, key}}`, `{:error, {:invalid_field, key}}`, `{:error, :underage}`, or `{:error, changeset}`.

9. **Keep functions short, at one level of detail.**
   `import_user/2` nests `try`, `if`, `if`, `case`, and `if`.
   Fix: a flat `with` over small steps (`parse_params/1`, `insert_user/1`).

10. **Fire-and-forget work goes under a supervisor, and send a process only the data it needs.**
    A bare `spawn/1` is unsupervised, so a crash in `Mailer.deliver` is lost. The closure also captures and copies the whole `user` struct.
    Fix: build the email first, then `Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)`. The task needs `Accounts.TaskSupervisor` in the supervision tree.

11. **Structs don't implement `Access`.**
    `user[:name]` raises `UndefinedFunctionError`, because `User` is a struct. The struct built here has no `:name` field either.
    Fix: read a field that exists, `user.nickname`.

12. **Don't pipe into an anonymous function.**
    `greeting |> (fn text -> ... end).()`.
    Fix: one interpolated string. The `"Hi " <> name <> ...` concatenation also becomes interpolation.

13. **Comments explain why, and docs go in `@moduledoc`/`@doc`.**
    Delete `# Get the role from params`, `# send the email`, and `# Import a single user ...`. Replace the module and function comments with `@moduledoc`, `@doc` and `@spec`. Keep the comment that explains the email lowercasing, since it gives a reason.

14. **Name magic numbers.**
    `120` and `18` become `@max_age` and `@min_age`.

15. **Read required keys with `map.key` or a pattern.**
    `params["email"]` returns `nil` for a missing key, and the failure then appears later in `String.downcase/1`. Fix: `string_field/2` returns `{:error, {:missing_field, key}}` where the key is missing.

Note: `Mailer` is not aliased in the original, and I left it as `Mailer`. Point it at the project's real module.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from external CSV/JSON rows.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from string-keyed `params`.

  Ages above #{@max_age} are capped at #{@max_age}.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.

  Returns `{:ok, user}`, `{:error, {:missing_field, key}}`,
  `{:error, {:invalid_field, key}}`, `{:error, {:unknown_role, role}}`,
  `{:error, :underage}`, or `{:error, changeset}` when the insert fails,
  for example because the email is taken.
  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, term()}
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, attrs} <- parse_params(params),
         {:ok, user} <- insert_user(attrs) do
      if opts[:notify], do: send_welcome(user)

      {:ok, user}
    end
  end

  defp parse_params(params) do
    with {:ok, email} <- string_field(params, "email"),
         {:ok, role} <- string_field(params, "role"),
         {:ok, role} <- parse_role(role),
         {:ok, age} <- string_field(params, "age"),
         {:ok, age} <- parse_age(age) do
      # The provider lowercases addresses before its uniqueness check, so match it here
      email = String.downcase(email)

      {:ok, %{email: email, age: age, role: role, nickname: params["nickname"] || email}}
    end
  end

  defp string_field(params, key) do
    case params do
      %{^key => value} when is_binary(value) -> {:ok, value}
      %{^key => _value} -> {:error, {:invalid_field, key}}
      %{} -> {:error, {:missing_field, key}}
    end
  end

  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("member"), do: {:ok, :member}
  defp parse_role(other), do: {:error, {:unknown_role, other}}

  defp parse_age(text) do
    case Integer.parse(text) do
      {age, ""} when age >= @min_age -> {:ok, min(age, @max_age)}
      {age, ""} when age < @min_age -> {:error, :underage}
      {_age, _rest} -> {:error, {:invalid_field, "age"}}
      :error -> {:error, {:invalid_field, "age"}}
    end
  end

  defp insert_user(%{role: role} = attrs) do
    %User{role: role}
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

Supporting change in `Accounts.User`. `:role` is deliberately not cast:

```elixir
def changeset(user, attrs) do
  user
  |> cast(attrs, [:email, :age, :nickname])
  |> validate_required([:email, :age, :nickname])
  |> unique_constraint(:email)
end
```
