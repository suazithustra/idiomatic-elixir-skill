# Review: `Accounts.UserImporter`

## Findings

1. **Bug: `age = 120` inside `if` has no effect** (rule: assign the result of `if`; rebinding inside a block does not escape it). `if age > 120 do age = 120 end` leaves `age` unchanged, so the cap never applies. Fix: `min(age, @max_age)`.

2. **Atom exhaustion** (rule: convert external strings to atoms with explicit clauses). `String.to_atom(params["role"])` lets any caller create atoms until the VM crashes. It also raises on a missing `"role"`. Fix: `parse_role/1` with one clause per accepted role, ending in `{:error, {:unknown_role, other}}`. The accepted roles `:admin`, `:member` are placeholders; replace them with the real list.

3. **`try/rescue _ ->` around the whole function** (rule: no `rescue` for expected failures; never `rescue _`). It hides real bugs (a misspelled function, a failing `Mailer`) as `{:error, :invalid}`. Fix: remove it and use non-raising calls (`Integer.parse/1`, `Map.fetch/2`).

4. **`String.downcase(nil)` runs before the `is_binary(email)` check**, so the check is useless and a missing email raises. Also `String.to_integer(params["age"])` raises on a missing or malformed age. Fix: read required string-keyed fields with `string_field/3`, which returns `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}`, chained with `with`.

5. **`Repo.insert(%User{...})` skips validation** (ecto-phoenix: validate input with changesets). Nothing is validated, and a unique-email violation raises, which the `rescue` then turns into `:invalid`. Fix: `User.changeset/2` with `unique_constraint(:email)`; `Repo.insert/1` then returns `{:error, changeset}`. **Assumption:** `User.changeset/2` exists or you add it. The file for `User` was not provided.

6. **`_ -> {:error, :insert_failed}` catch-all** (rule: match every expected shape). It throws away the changeset errors. Fix: pass `{:error, changeset}` through.

7. **`return_id` option changes the return shape** (rule: one return shape per function). With it the function returns a bare id, without it `{:ok, user}`. Fix: remove the option; the caller reads `user.id`.

8. **Overlapping booleans `notify` and `silent`** (rule: one atom-valued option instead of overlapping booleans). `notify: true, silent: true` is meaningless. Fix: keep only `:notify`, and check opts with `Keyword.validate!/2`. Document it under `## Options`.

9. **`&&` and `!` on booleans** (rule: `and`, `or`, `not` for booleans). `is_binary(email) && age >= 18` becomes `and`. The `opts[:notify] && !opts[:silent]` line goes away with finding 8.

10. **`spawn/1` outside a supervisor** (processes: supervise every long-lived process; send only the data needed). The mail job is unsupervised, and the closure copies the whole `user` struct. Fix: build the email in the caller and run `Task.Supervisor.start_child/2`, so only the email is copied. **Needs** `{Task.Supervisor, name: Accounts.TaskSupervisor}` in the application's supervision tree.

11. **`user[:name]` on a struct** (rule: structs do not implement `Access`). It raises `UndefinedFunctionError`. Fix: `user.name`. **Assumption:** `User` has a `:name` field; the constructor in the original only sets `email`, `age`, `role`, `nickname`, so if there is none, use `user.nickname`.

12. **Pipeline into an anonymous function; single-step pipe** (rule: pipelines). `greeting |> (fn ... end).()` and `params["email"] |> String.downcase()`. Fix: plain string interpolation and `String.downcase(email)`.

13. **Magic numbers 18 and 120** (rule: name them with module attributes). Fix: `@min_age`, `@max_age`.

14. **Comments that restate code** (`# Get the role from params`, `# send the email`, `# Import a single user…`) and no `@moduledoc`/`@doc`/`@spec` (rule: comments explain why; docs go in `@doc`). Fix: delete them, add docs. The comment about the provider lowercasing addresses explains a reason, so it is kept.

15. **Nested `case` inside `if` inside `try`** (rule: keep functions short, one level of detail). Fix: the public function is one `with` of named steps; details are in private functions.

Behavior changes to be aware of: errors are now specific (`{:missing_field, "age"}`, `:underage`, `{:unknown_role, "x"}`, a changeset) instead of `:invalid` and `:insert_failed`. Callers matching on the old atoms must be updated. I did not compile or run this, since `User`, `Repo`, and `Mailer` were not provided. `Mailer` is left unaliased as in the original.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from string-keyed params, such as rows from a CSV or JSON feed.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user.

  `params` must contain the string keys `"email"`, `"age"`, and `"role"`, and may
  contain `"nickname"`. Ages above #{@max_age} are capped at #{@max_age}.

  Returns `{:ok, user}`, or `{:error, reason}` where `reason` is
  `{:missing_field, key}`, `{:invalid_field, key}`, `{:unknown_role, role}`,
  `:underage`, or an `Ecto.Changeset` when the insert fails.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, term()}
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, email} <- string_field(params, "email"),
         {:ok, age} <- parse_age(params),
         {:ok, role} <- parse_role(params),
         {:ok, user} <- insert_user(email, age, role, params["nickname"]) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  defp insert_user(email, age, role, nickname) do
    # The provider lowercases addresses before its uniqueness check, so match it here
    email = String.downcase(email)

    %User{}
    |> User.changeset(%{email: email, age: age, role: role, nickname: nickname || email})
    |> Repo.insert()
  end

  defp parse_age(params) do
    with {:ok, text} <- string_field(params, "age"),
         {:ok, age} <- parse_integer(text, "age") do
      check_age(min(age, @max_age))
    end
  end

  defp check_age(age) when age >= @min_age, do: {:ok, age}
  defp check_age(_age), do: {:error, :underage}

  defp parse_integer(text, key) do
    case Integer.parse(text) do
      {integer, ""} -> {:ok, integer}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp parse_role(params) do
    with {:ok, role} <- string_field(params, "role") do
      role_atom(role)
    end
  end

  defp role_atom("admin"), do: {:ok, :admin}
  defp role_atom("member"), do: {:ok, :member}
  defp role_atom(other), do: {:error, {:unknown_role, other}}

  defp string_field(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
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
