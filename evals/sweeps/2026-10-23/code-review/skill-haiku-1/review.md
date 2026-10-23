# Review: `Accounts.UserImporter`

## Findings

1. **The welcome email is never sent.** `user[:name] || "there"` (line 558) raises `UndefinedFunctionError`, because `User` is a struct, structs do not implement `Access`, and `User` has no `:name` field. The raise happens inside `spawn`, so nothing is logged. Rule: "Read required keys with `map.key` or a pattern". Fix: `user.nickname` in `welcome_email/1`.

2. **The age cap never applies.** `if age > 120 do age = 120 end` (lines 520-522) rebinds `age` inside the `if`, and that value does not leave the block, so an age of 130 stays 130. Rule: "Assign the result of `if`, `case`, and `Enum` calls". Fix: `min(age, @max_age)` in `parse_age/1`.

3. **A blanket `rescue` hides every error.** `rescue _ -> {:error, :invalid}` (lines 547-549) wraps the whole body, so a bug in the code, a missing email, and a bad number all return the same `:invalid`. Rule: "rescue the specific exception, never `rescue _ ->`". Fix: remove the `try`; use `Integer.parse/1` and an `is_binary/1` guard.

4. **A duplicate-email check runs before the insert, and it can race.** `Repo.get_by(User, email: email) == nil` (line 529) followed by `Repo.insert` (line 530) lets two imports of the same address both pass the check. Rule: "Declare database constraints in the changeset (`unique_constraint/3`)". Fix: `unique_constraint(:email)` in `User.import_changeset/2`. The database also needs a unique index on `email`.

5. **`String.to_atom/1` turns input into atoms.** `role = String.to_atom(params["role"])` (line 513) lets any caller grow the atom table, which the VM never shrinks, and a missing role raises before the `try`. Rule: "Convert external strings to atoms with explicit clauses". Fix: `parse_role/1` with one clause per accepted role. The role names used here (`admin`, `editor`, `member`) are placeholders; replace them with the application's real roles.

6. **The struct goes straight to `Repo.insert/1`.** `user = %User{email: email, ...}` (line 527) is never validated. Rule: "Validate input with changesets". Fix: `User.import_changeset(%User{}, attrs)`, which casts and validates the fields.

7. **The insert error is swallowed.** `_ -> {:error, :insert_failed}` (line 538) turns every failure into one atom and drops the changeset that explains it. Rule: "Match every expected shape and let unexpected ones crash". Fix: `Repo.insert/1` returns `{:error, changeset}`, and `with` passes it through.

8. **The welcome email runs in an unsupervised process and copies the whole user.** `spawn(fn -> Mailer.deliver(welcome_email(user)) end)` (line 554) has no supervisor, so a crash is lost, and the closure copies `user` into the new process. Rule: "Supervise every long-lived process" and "Send processes only the data they need". Fix: `Task.Supervisor.start_child/2` under `Accounts.TaskSupervisor`, capturing only the built email string.

9. **`&&` and `!` are used on booleans.** `is_binary(email) && age >= 18` (line 526) and `opts[:notify] && !opts[:silent]` (line 532) accept any value. Rule: "Use `and`, `or`, `not` when the operands are booleans". Fix: both checks move into `parse_email/1` and `parse_age/1`, and the `:silent` option goes (see finding 10).

10. **Two options overlap.** `:notify` and `:silent` overlap, because `:silent` only cancels `:notify`. Rule: "Use one atom-valued field or option instead of overlapping booleans". Fix: remove `:silent`, so `:notify` alone decides. This is an API change: a caller that passes both must drop `silent:`.

11. **One option changes the return shape.** `if opts[:return_id], do: user.id, else: {:ok, user}` (line 536) returns an integer in one mode and a tuple in the other. Rule: "Give each function one return shape". Fix: remove `:return_id`; `import_user/2` always returns `{:ok, user}`, and a caller reads `user.id`. This is an API change.

12. **`String.to_integer/1` raises on bad input.** `age = String.to_integer(params["age"])` (line 518) raises on any non-number. Rule: "Call the non-raising version instead". Fix: `Integer.parse/1` in `parse_age/1`.

13. **One function holds five levels of nesting.** Lines 515-550 mix `try`, `if`, `case`, and `else`. Rule: "Keep functions short and at one level of detail" and "Chain fallible steps with `with`". Fix: a `with` over `user_attrs/1` and `Repo.insert/1`, with each parsing step in its own private function.

14. **Comments stand in for docs.** The module and function descriptions are comments (lines 507, 510), and several comments restate the code (lines 513, 553). Rule: "Document modules and public functions with `@moduledoc` and `@doc`". Fix: `@moduledoc`, and `@doc` with an `## Options` section. The one comment that gives a reason (line 516) stays, above `parse_email/1`.

15. **A single-step pipe and an anonymous function in a pipe.** `params["email"] |> String.downcase()` (line 517) pipes one step, and `greeting |> (fn text -> ... end).()` (line 560) pipes into an anonymous function. Rule: "Do not pipe a single step" and "Do not pipe into an anonymous function call". Fix: `parse_email/1` calls `String.downcase/1` directly, and the greeting is one interpolated string.

## Improved code

`accounts/user_importer.ex`:

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from external CSV (comma-separated values) or JSON (JavaScript Object Notation) sources.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports one user from string-keyed `params`.

  Returns `{:ok, user}` or `{:error, reason}`. The reason is `{:invalid_field, name}`
  when a field fails parsing, or an `Ecto.Changeset` when the database rejects the row,
  such as a duplicate email.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    with {:ok, attrs} <- user_attrs(params),
         {:ok, user} <- Repo.insert(User.import_changeset(%User{}, attrs)) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  defp user_attrs(params) do
    with {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         {:ok, role} <- parse_role(params["role"]) do
      {:ok, %{email: email, age: age, role: role, nickname: params["nickname"] || email}}
    end
  end

  # The provider lowercases addresses before its uniqueness check, so match it here
  defp parse_email(email) when is_binary(email), do: {:ok, String.downcase(email)}
  defp parse_email(_email), do: {:error, {:invalid_field, "email"}}

  defp parse_age(text) when is_binary(text) do
    case Integer.parse(text) do
      {age, ""} when age >= @min_age -> {:ok, min(age, @max_age)}
      _ -> {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(_text), do: {:error, {:invalid_field, "age"}}

  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("editor"), do: {:ok, :editor}
  defp parse_role("member"), do: {:ok, :member}
  defp parse_role(_role), do: {:error, {:invalid_field, "role"}}

  defp send_welcome(user) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user), do: "Hi #{user.nickname}, welcome! Enjoy your account."
end
```

## Companion changes this code needs

These live outside the module. The module will not compile against the real project without them.

`Accounts.User`, a `import_changeset/2` function:

```elixir
def import_changeset(user, attrs) do
  user
  |> cast(attrs, [:email, :age, :role, :nickname])
  |> validate_required([:email, :age, :role])
  |> unique_constraint(:email)
end
```

The database needs a unique index on `users.email`, or `unique_constraint/3` never fires.

The application's supervision tree needs a task supervisor:

```elixir
{Task.Supervisor, name: Accounts.TaskSupervisor}
```

## Checks run

- `mix format --check-formatted` passes on the improved file.
- The improved file was loaded with stub modules for `Accounts.Repo`, `Accounts.User`, and `Mailer`. The stubs stand in for Ecto, so the unique index and the database path are not tested. Results: a `130` age became `120`, the email was lowercased, the welcome email was sent, and bad age, short age, missing email, and unknown role each returned `{:error, {:invalid_field, _}}`.
