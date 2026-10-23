# Review: `Accounts.UserImporter`

Input: `code-review-input.ex`. Rules are from `idiomatic-elixir/SKILL.md`, plus `references/ecto-phoenix.md` (the module uses `Repo`) and `references/processes.md` (the module uses `spawn`).

## Findings

Ordered by severity. Correctness first, then rules that describe the same code.

1. **Correctness: the age clamp never happens.** `if age > 120 do age = 120 end` (lines 15-17). Rebinding inside `if` does not escape the block, so `age` stays unclamped and the compiler warns. Rule: *Assign the result of `if`, `case`, and `Enum` calls*. Fix: `age = min(age, @max_age)`.

2. **Correctness: the spawned welcome email crashes.** `user[:name] || "there"` (line 53). Structs do not implement `Access`, so this raises `UndefinedFunctionError` inside the spawned process, which dies silently. Rule: *Read required keys with `map.key`*. Fix: `user.nickname`, the field the importer actually sets. Behavior change: the greeting uses the nickname instead of always falling back to "there".

3. **Atoms from external input.** `String.to_atom(params["role"])` (line 8). Rule: *Convert external strings to atoms with explicit clauses*. It also crashes on a missing role, outside the `try`. Fix: declare `role` as `Ecto.Enum` in the schema and let `cast/3` convert it. Assumption: `User` has `field :role, Ecto.Enum, values: [...]`.

4. **Blanket rescue.** `rescue _ -> {:error, :invalid}` around the whole function (lines 42-43). Rule: *rescue only around third-party code, never `rescue _ ->` around a whole function*. The same block also hides real bugs. Fix: remove the `try`; use non-raising calls and return tuples.

5. **Raising parse for expected bad input.** `String.to_integer(params["age"])` (line 13). Rule: *Return `{:ok, value}` or `{:error, reason}` for expected failures*; call the non-raising version. Fix: `Integer.parse/1` in a small `parse_age/1` that returns `{:error, {:invalid_field, "age"}}`.

6. **Manual uniqueness check instead of a constraint.** `Repo.get_by(User, email: email) == nil` followed by `Repo.insert` (line 24). Rule: *Validate input with changesets* and the `unique_constraint/3` note. The check-then-insert is also racy. Fix: `unique_constraint(:email)` in `User.changeset/2`, and insert the changeset.

7. **Struct built by hand and inserted raw.** `%User{email: ..., age: ..., ...}` passed to `Repo.insert` (lines 22, 25). Rule: *Validate input with changesets*. Nothing validates the fields. Fix: `%User{} |> User.changeset(attrs) |> Repo.insert()`. The minimum-age check moves into the changeset (`validate_number(:age, greater_than_or_equal_to: 18)`).

8. **Catch-all error clause.** `_ -> {:error, :insert_failed}` (lines 33-34). Rule: *Match every expected shape and let unexpected ones crash*. Fix: `{:error, changeset}` passes the changeset through. Behavior change: callers that matched `:insert_failed` or `:invalid` must be updated.

9. **Overlapping booleans.** `opts[:notify] && !opts[:silent]` (line 27). Rule: *Use one atom-valued field or option instead of overlapping booleans*; `notify: true, silent: true` is the named example. Fix: a single `notify:` option with `:welcome` or `:none`. Also `&&` and `!` on options: use `and`/`not` only for booleans, so with the new atom option, compare with `==`.

10. **Option changes the return shape.** `if opts[:return_id], do: user.id, else: {:ok, user}` (line 31). Rule: *Give each function one return shape*. Fix: a separate `import_user_id/2` that returns `{:ok, id}`.

11. **Options not validated.** `opts[:notify]` on an unchecked keyword list. Rule: *Group related parameters*: check options with `Keyword.validate!/2` and document them under `## Options`. Fix: `Keyword.validate!(opts, notify: :none)`.

12. **Unsupervised `spawn`.** `spawn(fn -> Mailer.deliver(welcome_email(user)) end)` (line 49). Rule: *Supervise every long-lived process*; use `Task.Supervisor.start_child/2`. The closure also captures the whole `user` and builds the email inside the process. Rule: *Send processes only the data they need*: build the email in the caller and capture only that string. Assumption: `Accounts.TaskSupervisor` is in the application's supervision tree.

13. **Nested control flow.** Three levels of `if` and a `case` inside `try` (lines 15-44). Rule: *Branch with function clauses and guards*, and *Keep functions short and at one level of detail*. Fix: split into `parse_age/1`, `user_attrs/2`, `insert_user/2`, and a `with` over the steps. `is_binary(email) && age >= 18` also uses `&&` on booleans (rule: *Use `and`, `or`, `not`*), but the rewrite removes that expression.

14. **Dead type check.** The guard `is_binary(email)` (line 21) runs after `String.downcase/1` (line 12), so it never filters anything: `downcase` already raises on a non-binary. Rule: *Validate input with changesets*. Fix: `downcase_email/1` with a binary clause and a passthrough clause, and let `validate_required` report the missing email.

15. **Single-step pipe.** `params["email"] |> String.downcase()` (line 12). Rule: *Do not pipe a single step*. Fix: a plain call.

16. **Anonymous-function pipe.** `greeting |> (fn text -> text <> " Enjoy your account." end).()` (line 55). Rule: *Do not pipe into an anonymous function call*. Fix: one interpolated string.

17. **Magic numbers.** `120` and `18` (lines 15, 21). Rule: *Name magic numbers with module attributes*. Fix: `@max_age 120`; the 18 moves into the changeset.

18. **Missing docs; comments restate code.** No `@moduledoc`; the module comment (line 2) and the function comment (line 5) belong in `@moduledoc` and `@doc`. Comments on lines 7 (`# Get the role from params`) and 48 (`# send the email`) restate the code and go. Rule: *Comments explain why; documentation goes in `@moduledoc` and `@doc`*. Line 11 is a real reason and stays, moved above `downcase_email/1`.

19. **Function order.** Rule: *Put public functions before the private helpers they call*. Already satisfied in the original; kept in the rewrite.

## Assumptions

The rewrite needs a companion `User.changeset/2`. This module does not contain it; I have assumed roughly this shape:

```elixir
def changeset(user, attrs) do
  user
  |> cast(attrs, [:email, :age, :role, :nickname])
  |> validate_required([:email, :age, :role])
  |> validate_number(:age, greater_than_or_equal_to: 18)
  |> unique_constraint(:email)
end
```

with `field :role, Ecto.Enum, values: [...]` in the schema, and a `unique_index` on `users.email` in the database.

## Behavior changes to confirm with callers

- Errors are now `{:error, changeset}` for database and validation failures, and `{:error, {:invalid_field, "age"}}` for a non-integer age. Previously every failure was `{:error, :invalid}` or `{:error, :insert_failed}`.
- `:return_id` is gone; use `import_user_id/2`.
- `:silent` is gone; `notify: :welcome` replaces `notify: true`.
- Ages above 120 are now stored as 120. Before, the clamp never ran.
- Unknown roles fail the changeset. Before, `String.to_atom` created any atom.
- The welcome greeting uses the nickname.

## Verification

Not compiled or formatted: this environment has no Elixir project to run `mix format` or `mix compile` against. The rewrite was checked by reading against the rules above.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.{Repo, User}

  @max_age 120

  @doc """
  Imports a single user from string-keyed params.

  Returns `{:ok, user}` when the user is inserted. Returns
  `{:error, {:invalid_field, "age"}}` when the age is not an integer, and
  `{:error, changeset}` when validation or a database constraint rejects
  the user.

  ## Options

    * `:notify` - `:welcome` sends a welcome email after the insert.
      Defaults to `:none`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: :none)

    with {:ok, age} <- parse_age(params["age"]),
         {:ok, user} <- insert_user(params, age) do
      if opts[:notify] == :welcome, do: send_welcome(user)
      {:ok, user}
    end
  end

  @doc """
  Same as `import_user/2`, but returns `{:ok, id}` instead of the user.
  """
  def import_user_id(params, opts \\ []) do
    case import_user(params, opts) do
      {:ok, user} -> {:ok, user.id}
      {:error, _reason} = error -> error
    end
  end

  defp parse_age(text) when is_binary(text) do
    case Integer.parse(text) do
      {age, ""} -> {:ok, age}
      _ -> {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(_text), do: {:error, {:invalid_field, "age"}}

  defp insert_user(params, age) do
    %User{}
    |> User.changeset(user_attrs(params, age))
    |> Repo.insert()
  end

  defp user_attrs(params, age) do
    email = downcase_email(params["email"])

    %{
      email: email,
      age: min(age, @max_age),
      role: params["role"],
      nickname: params["nickname"] || email
    }
  end

  # The provider lowercases addresses before its uniqueness check, so match it here
  defp downcase_email(email) when is_binary(email), do: String.downcase(email)
  defp downcase_email(email), do: email

  defp send_welcome(user) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```
