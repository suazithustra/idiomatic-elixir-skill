# Review: `Accounts.UserImporter`

Read before reviewing: `SKILL.md`, `references/processes.md` (for `spawn`), `references/ecto-phoenix.md` (for `Repo`).

## Findings

1. **Bug: the age cap never applies.** Rule: "Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it."
   `if age > 120 do age = 120 end` rebinds `age` only inside the `if`, so ages above 120 pass through unchanged.
   Fix: `min(age, @max_age)`.

2. **`String.to_atom/1` on input.** Rule: "Convert external strings to atoms with explicit clauses."
   `role = String.to_atom(params["role"])` lets a caller exhaust the atom table, and it raises when `"role"` is missing.
   Fix: `parse_role/1` with one clause per accepted role and a `{:error, {:unknown_role, other}}` clause. The roles `:admin`, `:member` are placeholders; use the real set.

3. **`try/rescue` used to get an error tuple.** Rule: "Return `{:ok, value}` or `{:error, reason}` for expected failures."
   `rescue _ -> {:error, :invalid}` hides every bug, including typos, and merges all failures into one reason.
   Fix: `Integer.parse/1`, pattern matching and `with`, so each failure has its own reason.

4. **`String.to_integer/1` and `String.downcase/1` raise on bad input.** The same rule covers both.
   Fix: `parse_age/1` uses `Integer.parse/1` and returns `{:error, {:invalid_field, "age"}}`.

5. **Required keys read with `params["key"]`.** Rules: "Match the required keys of string-keyed input in a function head" and "Read required keys with `map.key` or a pattern".
   `params["email"] |> String.downcase()` turns a missing email into a crash far from the cause.
   Fix: match `"email"`, `"age"` and `"role"` in the head, with an `{:error, :invalid_params}` fallback clause. `nickname` is optional and stays `params["nickname"]`.

6. **Check-then-insert race.** Rule: changesets with `unique_constraint/3`.
   `Repo.get_by(User, email: email) == nil` followed by `Repo.insert/1` lets two imports of the same email both pass the check, and the second insert raises.
   Fix: `unique_constraint(:email)` in the changeset. A duplicate returns `{:error, changeset}`.

7. **Struct inserted without validation.** Rule: "Validate input with changesets."
   `%User{...}` goes to `Repo.insert/1` unvalidated.
   Fix: `User.import_changeset/2` casts, validates the age with `validate_number/3`, and declares the constraint. The age check moves out of the importer.

8. **`_ ->` catch-all after `{:ok, user}`.** Rule: "Match every expected shape."
   `_ -> {:error, :insert_failed}` throws away the changeset errors.
   Fix: `with` passes `{:error, changeset}` through.

9. **`is_binary(email)` checked after `String.downcase(email)`.** `String.downcase/1` has already raised for a non-binary, so the check can never fail.
   Fix: guard `is_binary(email)` in the function head.

10. **`&&` and `!` on booleans.** Rule: "Use `and`, `or`, `not` when the operands are booleans."
    `is_binary(email) && age >= 18` becomes a guard and a changeset validation, so both operators disappear.

11. **Overlapping booleans `notify` and `silent`.** Rule: "Use one atom-valued field or option instead of overlapping booleans."
    `opts[:notify] && !opts[:silent]` has a meaningless `notify: true, silent: true` case.
    Fix: a single `:notify` option, checked with `Keyword.validate!/2` and documented under `## Options`.

12. **Option changes the return shape.** Rule: "Give each function one return shape."
    `opts[:return_id]` returns a bare id instead of `{:ok, user}`.
    Fix: removed. The caller reads `user.id` from `{:ok, user}`.

13. **Unsupervised `spawn/1`.** Rule (`processes.md`): "Supervise every long-lived process", and fire-and-forget work uses `Task.Supervisor.start_child/2`.
    The closure also captures the whole `user`.
    Fix: build the email first and start the task under `Accounts.TaskSupervisor`, which must be in the supervision tree.

14. **`user[:name]` on a struct.** Rule: "Structs do not implement `Access`."
    `user[:name]` raises `UndefinedFunctionError`. Fix: `user.name`. This assumes `User` has an optional `:name` field; the original code never sets one.

15. **Pipe into an anonymous function.** Rule: "Do not pipe into an anonymous function call."
    Fix: one interpolated string.

16. **Deeply nested `if`/`case`/`if`, mixed levels of detail.** Rule: "Keep functions short and at one level of detail."
    Fix: a `with` chain of small private functions.

17. **Magic numbers 120 and 18.** Rule: "Name magic numbers with module attributes."
    Fix: `@max_age` here and `@minimum_age` in the changeset.

18. **Comments that restate code, docs as comments.** Rule: "Comments explain why; documentation goes in `@moduledoc` and `@doc`."
    Removed `# Get the role from params`, `# send the email` and the two header comments, and added `@moduledoc` and `@doc`. The comment about the provider lowercasing addresses explains why, so it stays.

19. **Generic error reason `:invalid`.** Rule: different failures need different reasons.
    Missing params, a bad age, an unknown role, an underage user and a duplicate email all returned `:invalid`. They now return distinct reasons.

20. **Unqualified `Mailer`.** Rule: "Put every module under the top-level namespace of its own application."
    I could not see the module, so I left `Mailer` as is. It probably should be `Accounts.Mailer`.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from string-keyed params, such as rows decoded from a CSV or JSON file.
  """

  alias Accounts.Repo
  alias Accounts.User

  @max_age 120

  @doc """
  Imports a single user.

  `params` must hold the string keys `"email"`, `"age"` and `"role"`;
  `"nickname"` is optional and defaults to the email.
  Ages above #{@max_age} are capped at #{@max_age}.

  Returns `{:ok, user}`, `{:error, changeset}` when validation fails or the
  email is taken, or `{:error, reason}` for malformed params.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ [])

  def import_user(%{"email" => email, "age" => age, "role" => role} = params, opts)
      when is_binary(email) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, role} <- parse_role(role),
         {:ok, age} <- parse_age(age),
         # The provider lowercases addresses before its uniqueness check, so match it here
         email = String.downcase(email),
         attrs = %{email: email, age: age, role: role, nickname: params["nickname"] || email},
         {:ok, user} <- insert_user(attrs) do
      if Keyword.fetch!(opts, :notify) do
        send_welcome(user)
      end

      {:ok, user}
    end
  end

  def import_user(_params, _opts), do: {:error, :invalid_params}

  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("member"), do: {:ok, :member}
  defp parse_role(other), do: {:error, {:unknown_role, other}}

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

  defp insert_user(attrs) do
    %User{}
    |> User.import_changeset(attrs)
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

Companion change in `Accounts.User` (required by findings 6, 7 and 17):

```elixir
@minimum_age 18

def import_changeset(user, attrs) do
  user
  |> cast(attrs, [:email, :age, :role, :nickname])
  |> validate_required([:email, :age, :role])
  |> validate_number(:age, greater_than_or_equal_to: @minimum_age)
  |> unique_constraint(:email)
end
```

`:role` should be an `Ecto.Enum` field, and the `users.email` column needs a unique index. The `with` clauses `email = ...` and `attrs = ...` are plain matches that cannot fail.

Not run: the module depends on `Accounts.User`, `Repo` and `Mailer`, which are not in the input, so I did not compile or format it.
