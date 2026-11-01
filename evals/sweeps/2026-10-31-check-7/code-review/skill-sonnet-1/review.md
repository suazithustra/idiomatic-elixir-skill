# Review of `Accounts.UserImporter`

## Findings

1. **`String.to_atom/1` on external input** (line 8: `role = String.to_atom(params["role"])`). Anyone who controls the CSV/JSON can exhaust the atom table and crash the node. A missing `"role"` also raises. Fix: explicit `parse_role/1` clauses ending in `{:error, {:unknown_role, other}}`.

2. **`try/rescue` with `rescue _ ->` around the whole function** (lines 10 and 42-43). It turns every bug (`String.to_integer/1` on bad input, `nil` email, a `Repo` crash) into `{:error, :invalid}`. Fix: use the non-raising `Integer.parse/1` and check input with `with` steps; remove the `try`.

3. **`if age > 120 do age = 120 end` does nothing** (lines 15-17). A rebinding inside `if` does not escape the block, so the age is never capped. Fix: `min(age, 120)`.

4. **`params["email"] |> String.downcase()` and `params["age"]` read required keys with `[]`** (lines 12-13). A missing key becomes `nil` and fails later in `String.downcase/1`, far from the cause. Fix: match `"email"`, `"age"` and `"role"` in the function head, with an `{:error, :invalid_payload}` fallback clause. This also drops the pipeline of a single step.

5. **`&&` and `!` on booleans** (line 21: `is_binary(email) && age >= 18`). Use `and`. Line 27 uses `&&` and `!` on `opts[:notify]`, which can be `nil`. That is replaced by finding 7.

6. **The `is_binary(email)` check comes after `String.downcase(email)`** (lines 12 and 21). The check can never be false, because `downcase` has already raised for a non-binary. Fix: `parse_email/1` with a binary guard and an error clause.

7. **Overlapping booleans and a changing return shape** (lines 27 and 31: `notify`, `silent`, `return_id`). `notify: true, silent: true` is contradictory, and `return_id` makes the function return either an integer or `{:ok, user}`. Fix: one option, `notify:` (default `false`), checked with `Keyword.validate!/2` and documented under `## Options`. The function always returns `{:ok, user}`; callers read `user.id`.

8. **Lookup before insert, and an unvalidated struct inserted directly** (lines 22-24: `Repo.get_by(...) == nil` and `Repo.insert(user)`). The lookup is a race: two imports can both pass it, and the second insert then raises. Nothing validates the struct. Fix: `User.changeset/2` with `unique_constraint(:email)`, so a duplicate returns `{:error, changeset}`.

9. **`_ ->` clause on the insert result** (lines 33-34). It hides the real changeset errors behind `:insert_failed`. Fix: pass `{:error, changeset}` through unchanged.

10. **One error reason for every failure** (`{:error, :invalid}` at lines 37, 40 and 43). Callers cannot tell a bad age, an underage user and a duplicate email apart. Fix: `{:error, {:invalid_field, "age"}}`, `{:error, :underage}`, and the changeset for a duplicate.

11. **Nested `if`/`case`/`if`** (lines 21-41). Fix: a `with` chain of small private steps (`parse_email/1`, `parse_age/1`, `parse_role/1`, `insert_user/1`).

12. **Bare `spawn/1` for the email, and the closure copies the whole `user`** (line 49). The process is unsupervised and its failures are lost. Fix: `Task.Supervisor.start_child/2`, and build the email before the closure so only the email is copied. This needs `{Task.Supervisor, name: Accounts.TaskSupervisor}` in the supervision tree.

13. **`user[:name]` on a struct** (line 53). Structs do not implement `Access`, so this raises `UndefinedFunctionError`. Fix: `user.name`.

14. **Piping into an anonymous function** (line 55: `greeting |> (fn text -> ... end).()`), and string building by `<>` in two steps. Fix: one interpolated string.

15. **Comments that restate the code**, and no `@moduledoc` or `@doc` (lines 2, 5, 7, 48). Fix: `@moduledoc` and `@doc` with examples of the options. The one comment that gives a reason (the provider lowercases addresses) is kept.

16. **Magic numbers** 18 and 120. Fix: `@minimum_age` and `@maximum_age`.

17. **Unqualified `Mailer`** (line 49). It sits outside the `Accounts` namespace. Fix: `alias Accounts.Mailer`.

## Assumptions

- `Accounts.User` has `changeset/2` that casts `:email`, `:age`, `:role`, `:nickname` and calls `unique_constraint(:email)`, backed by a unique index. Add that if it is not there.
- The accepted roles are `admin`, `editor` and `member`. Replace them with the real list.
- `Accounts.Mailer` and `Accounts.TaskSupervisor` exist.
- Callers that used `silent:` or `return_id:` must change. The first is covered by `notify:`; the second by reading `user.id`.
- I did not compile or run this.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV/JSON source.
  """

  alias Accounts.Mailer
  alias Accounts.Repo
  alias Accounts.User

  @minimum_age 18
  @maximum_age 120

  @doc """
  Imports a single user from string-keyed params.

  `"email"`, `"age"` and `"role"` are required; `"nickname"` defaults to the email.
  Ages above #{@maximum_age} are capped at #{@maximum_age}.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.

  Returns `{:ok, user}`, or `{:error, reason}` where `reason` is
  `:invalid_payload`, `:underage`, `{:invalid_field, field}`,
  `{:unknown_role, role}` or the changeset of the failed insert.
  """
  def import_user(params, opts \\ [])

  def import_user(%{"email" => email, "age" => age, "role" => role} = params, opts) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, email} <- parse_email(email),
         {:ok, age} <- parse_age(age),
         {:ok, role} <- parse_role(role),
         {:ok, user} <- insert_user(email, age, role, params["nickname"]) do
      if Keyword.fetch!(opts, :notify) do
        send_welcome(user)
      end

      {:ok, user}
    end
  end

  def import_user(_params, _opts), do: {:error, :invalid_payload}

  # The provider lowercases addresses before its uniqueness check, so match it here
  defp parse_email(email) when is_binary(email), do: {:ok, String.downcase(email)}
  defp parse_email(_email), do: {:error, {:invalid_field, "email"}}

  defp parse_age(age) when is_integer(age), do: check_age(age)

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {age, ""} ->
        check_age(age)

      _ ->
        {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(_age), do: {:error, {:invalid_field, "age"}}

  defp check_age(age) when age >= @minimum_age, do: {:ok, min(age, @maximum_age)}
  defp check_age(_age), do: {:error, :underage}

  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("editor"), do: {:ok, :editor}
  defp parse_role("member"), do: {:ok, :member}
  defp parse_role(other), do: {:error, {:unknown_role, other}}

  defp insert_user(email, age, role, nickname) do
    attrs = %{email: email, age: age, role: role, nickname: nickname || email}

    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp send_welcome(user) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user) do
    name = user.name || "there"
    "Hi #{name}, welcome! Enjoy your account."
  end
end
```
