# Review: `Accounts.UserImporter`

Source: `code-review-input.ex`. Rules are from `idiomatic-elixir` (`SKILL.md`), with `references/processes.md` (for `spawn`) and `references/ecto-phoenix.md` (for `Repo`) applied.

## Findings

Ordered by severity. Two are behavior bugs (1 and 2), not only style.

1. **Welcome email never sends correctly** (line 53, `user[:name] || "there"`). `user` comes from `Repo.insert/1`, so it is a struct. Structs do not implement `Access`, so `user[:name]` raises `UndefinedFunctionError`. The raise happens inside the `spawn`ed process, so nothing reports it. Read the field with `user.nickname`, which is always set (it defaults to the email).

2. **Age clamp never applies** (lines 15-17, `if age > 120 do age = 120 end`). Variables rebound inside `if` do not escape the block (*Assign the result of `if`, `case`, and `Enum` calls*). The value stays unclamped. Fix: `age = min(age, @max_age)`. This changes behavior for ages above 120, which now become 120 as the code intended.

3. **Atom leak from external input** (line 8, `String.to_atom(params["role"])`). Any caller can exhaust the atom table, and a `nil` role crashes (*Convert external strings to atoms with explicit clauses*). Pass the string into `User.changeset/2` and let `Ecto.Enum` cast it against the fixed list of roles.

4. **`rescue _ ->` around the whole function** (lines 10 and 42-44). This turns every bug into `{:error, :invalid}`, including a typo or a failed database call (*Return tuples for expected failures; raise only for bugs*). Remove it and use non-raising calls instead.

5. **Raising conversions inside `try`** (lines 12-13). `String.to_integer/1` raises on bad input. Use `Integer.parse/1`, which returns `{value, rest}` or `:error`. `String.downcase/1` raises on `nil`; check the type first.

6. **Single-step pipe** (line 12, `params["email"] |> String.downcase()`). Write the call directly (*Write pipelines that start with a value*). Finding 5 removes this line anyway.

7. **Check-then-insert race, struct inserted without a changeset** (lines 22-24, `Repo.get_by(User, email: email) == nil` followed by `Repo.insert(user)`). Two concurrent imports can both pass the check. Ecto skips validation for a bare struct. Build a changeset with `unique_constraint(:email)` and let the database reject duplicates (*Validate input with changesets*).

8. **Catch-all error hides the cause** (lines 33-34, `_ -> {:error, :insert_failed}`). The changeset with the reason is discarded. Return `{:error, changeset}` (*Match every expected shape*).

9. **Four different failures collapse into `{:error, :invalid}`** (lines 37, 40, 43). A duplicate email, an underage user, and a bad age all look the same to the caller. Use specific reasons: `{:invalid_field, key}`, `:underage`, or the changeset.

10. **Option changes the return shape** (line 31, `if opts[:return_id], do: user.id, else: {:ok, user}`). Callers get an integer or a tuple depending on a flag (*Give each function one return shape*). Split it into `import_user_id/2`. Note that `import_user_id/2` returns `{:ok, id}`, not a bare integer, so the shape is consistent. Callers that passed `return_id: true` must switch to the new function.

11. **Overlapping booleans** (line 27, `opts[:notify] && !opts[:silent]`). `silent` overrides `notify`, so the two options combine in only one useful way (*Use one atom-valued field or option instead of overlapping booleans*). The improved code drops `:silent` and keeps `:notify`. Removing `:silent` is an API change: callers that pass it now get an error from `Keyword.validate!/2`.

12. **Boolean operators on possibly non-boolean operands** (lines 21 and 27, `&&`, `!`). `opts[:notify]` may be `nil`, and `and`/`or`/`not` raise on non-booleans, so they document intent (*Use `and`, `or`, `not` when the operands are booleans*). The improved code validates options with `Keyword.validate!/2`, which makes the `&&` unnecessary.

13. **Unsupervised process** (line 49, `spawn(fn -> ... end)`). The mail process has no supervisor, no restart, and no visibility in Observer (*Supervise every long-lived process*). Use `Task.Supervisor.start_child/4` with an MFA, which also avoids capturing the closure. Requires `{Task.Supervisor, name: Accounts.TaskSupervisor}` in the application's supervision tree.

14. **Pipe into an anonymous function** (line 55, `greeting |> (fn text -> ... end).()`). This is the form the skill rules out (*Write pipelines that start with a value*). Build the string with interpolation.

15. **Options not validated or documented** (line 6, `opts \\ []`). Unknown keys are ignored silently. Use `Keyword.validate!/2` and document the options under `## Options` in `@doc` (*Group related parameters*).

16. **Comments restate the code, and documentation is in comments** (lines 2, 5, 7, 48). "Get the role from params" and "send the email" say what the next line already says; delete them. The module comment and the function comment belong in `@moduledoc` and `@doc` (*Comments explain why*). Keep line 11: it explains a reason the code cannot show.

17. **Magic numbers** (lines 15, 21, `120` and `18`). Name them with module attributes (*Name magic numbers with module attributes*).

18. **Deep nesting** (lines 15-44). Four levels of `if` and `case` in one function. Use a `with` over named steps, with each step in a private function (*Chain fallible steps with `with`*; *Keep functions short*).

## Assumptions about code outside this file

The improved code assumes the following. These are outside the file, so check them in the project:

- `Accounts.User` has `email`, `age`, `role` (an `Ecto.Enum` field), and `nickname`, and no `name` field.
- `Accounts.User.changeset/2` casts those fields, validates them as required, and calls `unique_constraint(:email)`. A sketch:

  ```elixir
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :age, :role, :nickname])
    |> validate_required([:email, :age, :role])
    |> unique_constraint(:email)
  end
  ```

- A unique index on `users.email` exists. Without it, `unique_constraint/3` never fires and duplicates get through.
- `Accounts.TaskSupervisor` is started in the application's supervision tree.

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
  Imports a single user from string-keyed params.

  Returns `{:ok, user}` or `{:error, reason}`. The reason is `{:invalid_field, key}`
  for a missing or malformed field, `:underage` for someone under 18, or a changeset
  when the database rejects the values, such as a duplicate email.

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

  @doc """
  Imports a single user and returns `{:ok, id}`.

  Takes the same options as `import_user/2`.
  """
  def import_user_id(params, opts \\ []) do
    case import_user(params, opts) do
      {:ok, user} -> {:ok, user.id}
      {:error, _reason} = error -> error
    end
  end

  defp build_attrs(params) do
    with {:ok, email} <- fetch_email(params),
         {:ok, age} <- parse_age(params["age"]) do
      attrs = %{
        email: email,
        age: age,
        role: params["role"],
        nickname: params["nickname"] || email
      }

      {:ok, attrs}
    end
  end

  # The provider lowercases addresses before its uniqueness check, so match it here
  defp fetch_email(%{"email" => email}) when is_binary(email) do
    {:ok, String.downcase(email)}
  end

  defp fetch_email(_params), do: {:error, {:invalid_field, "email"}}

  defp parse_age(value) when is_binary(value) do
    case Integer.parse(value) do
      {age, ""} -> check_age(age)
      _ -> {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(_value), do: {:error, {:invalid_field, "age"}}

  defp check_age(age) when age < @min_age, do: {:error, :underage}
  defp check_age(age), do: {:ok, min(age, @max_age)}

  defp insert_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp send_welcome(user) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, Mailer, :deliver, [email])
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

## Behavior changes to confirm

- Ages above 120 are now stored as 120 (finding 2). The original code intended this but never did it.
- Welcome emails now send. The original raised in the spawned process on every call (finding 1).
- `import_user/2` returns specific error reasons instead of `:invalid`, and no longer returns an integer id (finding 10).
- `:silent` is no longer accepted (finding 11).
- Invalid input raises instead of returning `{:error, :invalid}` if it reaches a bug in the code, not only bad data (finding 4).
