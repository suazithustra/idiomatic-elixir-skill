# Review of `Accounts.UserImporter`

The skill's reference files for processes (`spawn`) and Ecto (`Repo`) were read first.

## Findings

1. **Bug: the age cap never applies.** Rule: "Assign the result of `if`, `case`, and `Enum` calls". Line `if age > 120 do age = 120 end` rebinds `age` only inside the `if`. A 200-year-old user is inserted as 200. Fix: `min(age, @max_age)`.

2. **`String.to_atom/1` on external input.** Rule: "Convert external strings to atoms with explicit clauses". Line `role = String.to_atom(params["role"])` lets a caller exhaust the atom table. It also raises on a missing role (`nil`). Fix: cast the role through an `Ecto.Enum` field in the changeset, which accepts only the listed values.

3. **`try/rescue _ ->` around the whole function.** Rule: "Return `{:ok, value}` or `{:error, reason}` for expected failures". Line `rescue _ -> {:error, :invalid}` turns every bug (a typo, a database outage, `Repo.insert` raising) into `:invalid`. Fix: use non-raising calls (`Integer.parse/1`, a pattern on the params) and remove the `try`.

4. **`String.to_integer/1` raises on bad input.** Same rule. Fix: `parse_age/1` uses `Integer.parse/1` and returns `{:error, {:invalid_field, "age"}}`.

5. **Hand-built validation and a lookup before insert.** Reference `ecto-phoenix.md`: "Validate input with changesets". The code builds `%User{...}` directly, checks age by hand, and calls `Repo.get_by(...) == nil` before `Repo.insert`. That lookup is a race: two imports of the same address can both pass it, and one then hits the database constraint and raises. Fix: `User.changeset/2` with `validate_number/3` and `unique_constraint/2`, so a duplicate returns `{:error, changeset}`.

6. **Single `_ ->` clause hides the insert error.** Rule: "Match every expected shape". Line `_ -> {:error, :insert_failed}` drops the changeset. All failures also collapse to `:invalid`, so callers cannot tell a duplicate from a bad age. Fix: pass `{:error, changeset}` through, and return specific reasons for parse failures.

7. **Overlapping booleans.** Rule: "Use one atom-valued field or option instead of overlapping booleans". Line `opts[:notify] && !opts[:silent]`: `silent: true` overrides `notify: true`. Fix: a single `notify` option, validated with `Keyword.validate!/2`.

8. **Option changes the return shape.** Rule: "Give each function one return shape". Line `if opts[:return_id], do: user.id, else: {:ok, user}`. Fix: remove `:return_id`. Callers that need the id use `{:ok, user} = import_user(...)` and `user.id`.

9. **Nested `if`/`case`/`if`.** Rule: "Chain fallible steps with `with`" and "Keep functions short and at one level of detail". Four levels of nesting. Fix: `with` over `build_attrs/1` and `insert_user/1`, plus small private functions.

10. **`&&` and `!` on booleans.** Rule: "Use `and`, `or`, `not` when the operands are booleans". Line `is_binary(email) && age >= 18`. The `is_binary(email)` check is also useless after `String.downcase(email)`, which already raised on non-binaries. Fix: `is_binary(email)` goes in a function-head guard.

11. **Bare `spawn` for the email.** Reference `processes.md`: "Supervise every long-lived process". An unsupervised `spawn` loses failures silently and has no shutdown handling. Fix: `Task.Supervisor.start_child/2` under `Accounts.TaskSupervisor`. The email is built before the call so the closure copies only the email, not the whole user. This needs `{Task.Supervisor, name: Accounts.TaskSupervisor}` in the supervision tree.

12. **`user[:name]` on a struct.** Rule: "Read required keys with `map.key`". `%User{}` has no `Access`, so `welcome_email/1` raises `UndefinedFunctionError`. Fix: `user.name || "there"`.

13. **Piping into an anonymous function.** Rule: "Write pipelines that start with a value". Line `greeting |> (fn text -> ... end).()`. Fix: build the string once with interpolation.

14. **Comments that restate the code, and no docs.** Rule: "Comments explain why". Deleted: `# Get the role from params`, `# send the email`, `# Import a single user ...`, `# This module imports ...`. Kept: the comment about the provider lowercasing addresses, since it gives a reason. Added `@moduledoc` and `@doc` with `## Options`.

15. **Magic numbers.** Rule: "Name magic numbers with module attributes". `18` and `120` become `@min_age` (in `User`) and `@max_age`.

16. **Params are not parsed at the boundary.** Rule: "Match the required keys of string-keyed input in a function head". `params["email"]` is read without checking that it exists. Fix: `build_attrs/1` matches `"email"`, `"age"` and `"role"` in its head, with a catch-all returning `{:error, :invalid_params}`.

## Assumptions

- `User` is an Ecto schema. Its `role` field becomes an `Ecto.Enum` (the values below are placeholders for the real ones).
- `Mailer` is left as written. If it lives under `Accounts`, alias it.
- The `:return_id` option is removed. Callers using it must switch to `{:ok, user}`.
- The age floor of 18 moves into `User.changeset/2`, so an under-age import returns `{:error, changeset}` instead of `{:error, :invalid}`.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.Repo
  alias Accounts.User

  @max_age 120

  @doc """
  Imports a single user from string-keyed params.

  Returns `{:ok, user}`, `{:error, :invalid_params}` when `"email"`, `"age"`
  or `"role"` is missing, `{:error, {:invalid_field, "age"}}` when the age is
  not an integer, or `{:error, changeset}` when validation or the unique
  email constraint fails. Ages above #{@max_age} are capped at #{@max_age}.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, attrs} <- build_attrs(params),
         {:ok, user} <- insert_user(attrs) do
      if opts[:notify], do: send_welcome(user)

      {:ok, user}
    end
  end

  defp build_attrs(%{"email" => email, "age" => age, "role" => role} = params)
       when is_binary(email) do
    with {:ok, age} <- parse_age(age) do
      # The provider lowercases addresses before its uniqueness check, so match it here
      email = String.downcase(email)

      {:ok,
       %{
         email: email,
         age: min(age, @max_age),
         role: role,
         nickname: params["nickname"] || email
       }}
    end
  end

  defp build_attrs(_params), do: {:error, :invalid_params}

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {age, ""} ->
        {:ok, age}

      {_age, _rest} ->
        {:error, {:invalid_field, "age"}}

      :error ->
        {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(_age), do: {:error, {:invalid_field, "age"}}

  defp insert_user(attrs) do
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

Supporting change in `Accounts.User` (the schema module, not shown in the input):

```elixir
@min_age 18

schema "users" do
  # ...
  field :role, Ecto.Enum, values: [:admin, :editor, :member]
end

def changeset(user, attrs) do
  user
  |> cast(attrs, [:email, :age, :role, :nickname])
  |> validate_required([:email, :age, :role])
  |> validate_number(:age, greater_than_or_equal_to: @min_age)
  |> unique_constraint(:email)
end
```
