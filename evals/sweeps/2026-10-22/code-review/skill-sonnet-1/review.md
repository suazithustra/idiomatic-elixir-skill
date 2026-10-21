# Review of `Accounts.UserImporter`

Reference files read: `processes.md` (the code uses `spawn`) and `ecto-phoenix.md` (the code uses `Repo`).

## Findings

1. **`String.to_atom/1` on input** (line 8, `String.to_atom(params["role"])`). Rule: convert external strings to atoms with explicit clauses. Anyone who controls `role` can exhaust the atom table and crash the node. A missing `role` also raises on `nil`. Fix: `parse_role/1` with one clause per accepted role and an `{:error, {:invalid_field, "role"}}` fallback.

2. **`try/rescue` with `rescue _ ->` around the whole function** (lines 10 and 38-40). Rule: return tuples for expected failures; never rescue broadly. It turns every bug, such as a typo or a missing key, into `{:error, :invalid}`. Fix: remove it and use `Integer.parse/1` and pattern matches, so bad input returns a specific error.

3. **`String.to_integer/1` on input** (line 13). Rule: use the non-raising version. A non-numeric `age` raised and was hidden by the `rescue`. Fix: `Integer.parse/1` in `parse_age/1`.

4. **Required keys read with `params["email"]`, checked too late** (lines 12 and 21). Rule: required keys are not read with `map[:key]`. A missing email makes `String.downcase(nil)` raise. The later `is_binary(email)` can never be false, because `String.downcase/1` has already returned a string. Fix: `string_field/2` returns `{:error, {:missing_field, key}}` or `{:invalid_field, key}`, chained with `with`.

5. **Rebinding inside `if` does not escape it** (lines 15-17, `if age > 120 do age = 120 end`). Rule: assign the result of `if`. The outer `age` is never clamped, and the compiler warns. Fix: `min(age, @max_age)`.

6. **`&&` and `!` on non-obvious values** (lines 21 and 26). Rule: use `and`, `or`, `not` for booleans. Fix: `and` on line 21. The `opts` check is removed by finding 7.

7. **Overlapping boolean options** (`notify` and `silent`, line 26). Rule: use one option, not overlapping booleans. `notify: true, silent: true` is contradictory. Fix: keep only `:notify`, and check options with `Keyword.validate!/2`.

8. **Option changes the return shape** (line 30, `return_id` returns `user.id` instead of `{:ok, user}`). Rule: one return shape per function. It also loses the error-tuple contract. Fix: always return `{:ok, user}`. A caller who wants the ID reads `user.id`.

9. **`_ ->` on `Repo.insert/1` hides the reason** (lines 32-33). Rule: match every expected shape. A changeset error with the field errors becomes `:insert_failed`. Fix: match `{:error, changeset}` and return it.

10. **Unvalidated struct passed to `Repo.insert/1`** (line 22). Rule (`ecto-phoenix.md`): validate input with changesets. A unique-constraint violation on email raises instead of returning `{:error, changeset}`. Fix: build the user with `User.changeset/2`, with `unique_constraint(:email)` declared there. The version below assumes `User.changeset/2` casts `:email`, `:age`, `:role`, `:nickname` and declares that constraint. If your schema lacks it, add it.

11. **Unsupervised `spawn/1`** (line 45). Rule (`processes.md`): supervise long-lived or background work. A crash in `Mailer.deliver/1` is invisible and nothing is shut down cleanly. Fix: `Task.Supervisor.start_child/2` under `Accounts.TaskSupervisor`, which must be in the supervision tree. Only the email is captured, not the whole `user`.

12. **`user[:name]` on a struct** (line 49). Rule: structs do not implement `Access`, so this raises `UndefinedFunctionError`. Fix: `user.name`. This assumes `User` has a `:name` field. If it does not, the original would have raised, so the field must be added or the greeting changed.

13. **Piping into an anonymous function** (line 51) and **string building with `<>`**. Rule: do not pipe into `(fn ... end).()`. Fix: one interpolated string.

14. **Nested control flow in one function** (`try` > `if` > `case` > `if`). Rule: keep functions short and at one level of detail. Fix: a `with` of small steps; the notify branch is its own function.

15. **Comments that restate code** (lines 2, 5, 7, 44) and **no `@moduledoc` or `@doc`**. Rule: comments explain why; document public functions with `@doc`. Fix: delete the restating comments and keep the one on line 11, which gives a reason. Add `@moduledoc`, `@doc` with `## Options`, and an `@spec`.

16. **Magic numbers** 18 and 120. Rule: name them with module attributes (`@min_age`, `@max_age`).

Behavior changes to be aware of: malformed input now returns specific errors instead of `{:error, :invalid}`, `age` above 120 is clamped (as the original intended), and the `silent` and `return_id` options are removed. Role names (`admin`, `editor`, `member`) are placeholders; use your real list.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from string-keyed `params`.

  Requires `"email"`, `"age"`, and `"role"`. `"nickname"` is optional and
  defaults to the email.

  Returns `{:ok, user}`, `{:error, {:missing_field, key}}`,
  `{:error, {:invalid_field, key}}`, or `{:error, changeset}`.

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

  defp string_field(params, key) do
    case params do
      %{^key => value} when is_binary(value) -> {:ok, value}
      %{^key => _value} -> {:error, {:invalid_field, key}}
      %{} -> {:error, {:missing_field, key}}
    end
  end

  defp parse_age(params) do
    with {:ok, text} <- string_field(params, "age"),
         {age, ""} when age >= @min_age <- Integer.parse(text) do
      {:ok, min(age, @max_age)}
    else
      {:error, _reason} = error -> error
      _ -> {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_role(params) do
    with {:ok, text} <- string_field(params, "role") do
      role_from_string(text)
    end
  end

  defp role_from_string("admin"), do: {:ok, :admin}
  defp role_from_string("editor"), do: {:ok, :editor}
  defp role_from_string("member"), do: {:ok, :member}
  defp role_from_string(_other), do: {:error, {:invalid_field, "role"}}

  defp insert_user(email, age, role, nickname) do
    # The provider lowercases addresses before its uniqueness check, so match it here
    email = String.downcase(email)

    %User{}
    |> User.changeset(%{email: email, age: age, role: role, nickname: nickname || email})
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

Note on `parse_age/1`: its `else` has a catch-all because `Integer.parse/1` can return `:error` or `{age, rest}`, and all of those, plus an age under 18, map to the same `{:invalid_field, "age"}`. That is the only `with` with an `else`; splitting it further would not add information.
