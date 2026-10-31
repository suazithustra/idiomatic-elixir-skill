# Review: `Accounts.UserImporter`

The importer crashes or silently does the wrong thing on bad input, then hides the crash behind a catch-all `rescue`. Every failure comes back as `{:error, :invalid}`, so a caller cannot tell a bad role from a duplicate email. The rewrite is at the end. I formatted it with `mix format`; I did not compile it, because `Accounts.Repo`, `User` and `Mailer` are not available here.

## Findings

1. **Atoms made from input.** Rule: convert external strings to atoms with explicit clauses. Line: `role = String.to_atom(params["role"])`. Anyone who controls the CSV can exhaust the VM's (virtual machine's) atom table, and a missing `"role"` raises. Fix: `parse_role/1` with one clause per accepted role and `{:error, {:unknown_role, other}}` for the rest. The roles `admin`, `editor` and `member` are my guess; replace them with the real list.

2. **`try/rescue _` around the whole function.** Rule: return tuples for expected failures; never `rescue _ ->` around a function. Line: `rescue _ -> {:error, :invalid}`. It also hides real bugs such as a missing `Mailer`. Fix: remove the `try` and use non-raising calls (`Integer.parse/1`, pattern-matched params).

3. **`String.to_integer/1` on input.** Rule: use the non-raising version. Line: `age = String.to_integer(params["age"])`. Non-numeric or missing ages raise. Fix: `parse_age/1` using `Integer.parse/1`, returning `{:error, {:invalid_field, "age"}}`.

4. **Rebinding inside `if` has no effect.** Rule: assign the result of `if`. Lines: `if age > 120 do age = 120 end`. The outer `age` is never capped, and the compiler warns. Fix: `min(age, @max_age)`, with `@max_age` named.

5. **Required keys read with `params["key"]`.** Rule: match required keys in the head and give the no-match case its own clause. Lines: `params["email"]`, `params["age"]`, `params["role"]`. Fix: `def import_user(%{"email" => email, "age" => age, "role" => role} = params, opts) when is_binary(email)`, plus `def import_user(_params, _opts), do: {:error, :invalid_params}`. `params["nickname"] || email` stays, since it is optional.

6. **`&&` and `!` on booleans.** Rule: use `and`, `or`, `not` for booleans. Lines: `is_binary(email) && age >= 18` and `opts[:notify] && !opts[:silent]`. The `is_binary(email)` check also came after `String.downcase(email)` had already run, so it could never fail. Fix: the guard in the head (finding 5); the age check moves to the changeset (finding 8).

7. **Overlapping booleans.** Rule: one option instead of overlapping booleans. Line: `opts[:notify] && !opts[:silent]`. `notify: true, silent: true` is meaningless. Fix: keep only `:notify`, validated with `Keyword.validate!/2` and documented under `## Options`.

8. **Unvalidated struct insert.** Rule: validate input with changesets. Line: `user = %User{email: email, age: age, role: role, nickname: nickname}` then `Repo.insert(user)`. Nothing is validated, and a constraint violation raises. Fix: `%User{} |> User.changeset(attrs) |> Repo.insert()`. `User.changeset/2` must cast `email`, `age`, `role`, `nickname`, call `validate_number(:age, greater_than_or_equal_to: 18)`, and declare `unique_constraint(:email)`. I could not see `User`, so check that it does.

9. **Lookup before insert.** Rule: use `unique_constraint/3` instead of checking by hand. Line: `if Repo.get_by(User, email: email) == nil do`. Two imports of the same email can both pass the check and both insert. Fix: delete the lookup and let `unique_constraint(:email)` return `{:error, changeset}`. It needs a unique index on the lowercased email.

10. **Catch-all error clause.** Rule: match every expected shape. Line: `_ -> {:error, :insert_failed}`. It throws away the changeset. Fix: pass `{:error, changeset}` through unchanged.

11. **Two return shapes.** Rule: one return shape per function. Line: `if opts[:return_id], do: user.id, else: {:ok, user}`. Fix: remove the option; callers read `user.id` from `{:ok, user}`. If you need an ID-only function, make it a separate one. This changes the public API, so check the callers first.

12. **Nested control flow in one function.** Rule: keep functions short and at one level of detail; chain fallible steps with `with`. The `try`, `if`, `if`, `case`, `if` nesting is replaced by one `with` over `parse_role`, `parse_age` and `insert_user`, each returning `{:ok, value}` or `{:error, reason}`.

13. **Unsupervised `spawn`.** Rule: supervise long-lived processes; fire-and-forget work uses `Task.Supervisor.start_child/2`. Line: `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`. A crash is lost without a trace, and shutdown does not wait for it. Fix: `Task.Supervisor.start_child(Accounts.TaskSupervisor, ...)`. Add `{Task.Supervisor, name: Accounts.TaskSupervisor}` to the supervision tree.

14. **`user[:name]` on a struct.** Rule: structs do not implement `Access`. Line: `name = user[:name] || "there"`. It raises `UndefinedFunctionError`. Fix: read a field with `user.nickname`. I used `nickname` because `User` is built here with `nickname` and not `name`. The greeting now says "Hi <email>" when no nickname was given, because the nickname defaults to the email. If you want "there" as the fallback, say so and I will change it.

15. **Pipe into an anonymous function.** Rule: do not pipe into `(fn ... end).()`. Lines: `greeting |> (fn text -> text <> " Enjoy your account." end).()`. Fix: one interpolated string.

16. **Comments that restate code, and no docs.** Rule: comments explain why; use `@moduledoc` and `@doc`. Removed `# Get the role from params`, `# send the email`, the header comments, and the comment above the module. Kept the comment about the provider lowercasing addresses, since it gives a reason. Added `@moduledoc`, `@doc` with `## Options`, and `@spec`.

17. **Vague error reasons.** Rule: use tagged tuples that callers can match. Every failure was `:invalid`. The rewrite returns `:invalid_params`, `{:unknown_role, role}`, `{:invalid_field, "age"}`, or the changeset.

## Behavior changes

- Ages above 120 are capped as before, but now the cap works.
- Underage users now fail in the changeset with a changeset error, not `{:error, :invalid}`.
- `:silent` and `:return_id` options are gone, and `Keyword.validate!/2` raises on them.
- `Mailer` is unqualified in the original and I left it that way.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV/JSON source.
  """

  alias Accounts.{Repo, User}

  @max_age 120

  @doc """
  Imports a single user from string-keyed `params`.

  `params` must hold `"email"`, `"age"` and `"role"` as strings; `"nickname"`
  is optional and defaults to the email. An age above #{@max_age} is stored as
  #{@max_age}. Returns `{:error, %Ecto.Changeset{}}` when validation fails or
  the email is already taken.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, term()}
  def import_user(params, opts \\ [])

  def import_user(%{"email" => email, "age" => age, "role" => role} = params, opts)
      when is_binary(email) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, role} <- parse_role(role),
         {:ok, age} <- parse_age(age),
         {:ok, user} <- insert_user(params, role, age) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  def import_user(_params, _opts), do: {:error, :invalid_params}

  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("editor"), do: {:ok, :editor}
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

  defp insert_user(%{"email" => email} = params, role, age) do
    # The provider lowercases addresses before its uniqueness check, so match it here
    email = String.downcase(email)
    attrs = %{email: email, age: age, role: role, nickname: params["nickname"] || email}

    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp send_welcome(user) do
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn ->
      Mailer.deliver(welcome_email(user))
    end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

The same code is in `improved.ex` next to this file.
