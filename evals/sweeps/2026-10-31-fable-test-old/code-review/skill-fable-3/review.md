# Review: `Accounts.UserImporter`

The module takes untrusted import rows, converts them to atoms without a whitelist, validates them with nested `if`s inside a blanket `rescue`, and then checks uniqueness with a read-then-insert that races. The welcome email is sent from an unsupervised process that crashes every time it runs, because it reads a struct with `user[:name]`. The fix is to validate with an `Ecto.Changeset`, let the database enforce uniqueness, and hand the email to a `Task.Supervisor`.

Assumptions the improved version makes about code outside this file: the `User` schema declares `role` as `Ecto.Enum` with the accepted values, the `users` table has a unique index on `email`, `Accounts.TaskSupervisor` is started in the application's supervision tree, and the mailer is `Accounts.Mailer`.

## Findings

1. **Convert external strings to atoms with explicit clauses.** Line 8, `role = String.to_atom(params["role"])`, lets whoever controls the import file create unbounded atoms and exhaust the atom table. It also runs outside the `try`, so a row with no `"role"` crashes the caller with `ArgumentError`. Fix: cast `role` through the changeset onto an `Ecto.Enum` field, which only accepts the listed values and reports `"is invalid"` otherwise. If `User` cannot use `Ecto.Enum`, write `defp parse_role("admin"), do: {:ok, :admin}` clauses with a final `parse_role(other), do: {:error, {:unknown_role, other}}`.

2. **Return tuples for expected failures; never `rescue _ ->` around a whole function.** Lines 10 and 42 to 43, `try do ... rescue _ -> {:error, :invalid} end`, turn every exception, including bugs such as the `KeyError` from a misspelled field, into the same `{:error, :invalid}`. Fix: remove the `try`. `cast/3` handles a missing or non-integer `"age"` and a non-string `"email"` and records which field failed.

3. **Validate input with changesets, not hand checks, and declare `unique_constraint/3` instead of a lookup before insert.** Line 22 builds `%User{email: email, age: age, role: role, nickname: nickname}` and line 25 inserts it unvalidated. Line 24, `if Repo.get_by(User, email: email) == nil do`, is a read-then-write: two concurrent imports of the same address both pass the check and the second insert raises on the index. Fix: `%User{} |> cast(params, [...]) |> validate_required([...]) |> validate_number(:age, ...) |> unique_constraint(:email) |> Repo.insert()`, which returns `{:error, changeset}` for a duplicate.

4. **Assign the result of `if`; rebinding inside a block does not escape it.** Lines 15 to 17, `if age > 120 do age = 120 end`, never change `age`, and the compiler warns that the inner `age` is unused. The cap the code intends has never applied. Fix: `update_change(:age, &min(&1, @max_age))`. I kept the clamp because the code clearly intends it, but I would reject an age over 120 with `validate_number(:age, less_than_or_equal_to: @max_age)` instead, since silently rewriting a value hides bad source data.

5. **Match every expected shape and let unexpected ones crash.** Line 33, `_ -> {:error, :insert_failed}`, discards the changeset that explains why the insert failed and would also swallow any new return shape. Fix: `{:error, _changeset} = error -> error`.

6. **Give each function one return shape.** Line 31, `if opts[:return_id], do: user.id, else: {:ok, user}`, makes the return type depend on an option, so callers cannot pattern match on it reliably. Fix: always return `{:ok, user}` and drop `:return_id`; the caller reads `user.id`.

7. **Use one atom-valued field or option instead of overlapping booleans.** Line 27, `if opts[:notify] && !opts[:silent] do`, has two options where `silent: true` only ever overrides `notify: true`. Fix: keep `:notify` alone, validated with `Keyword.validate!(opts, notify: false)` and documented under `## Options`.

8. **Supervise every long-lived process; use `Task.Supervisor.start_child/2` for fire-and-forget work.** Line 49, `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`, is invisible to the supervision tree and to shutdown, and its crashes are only logged. Fix: `Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)`.

9. **Send processes only the data they need.** The same line captures the whole `user` struct in the closure, so the entire struct is copied into the new process to read one field. Fix: build the email in the calling process, `email = welcome_email(user)`, and capture only `email`.

10. **Structs do not implement `Access`; read fields with `user.field`.** Line 53, `name = user[:name] || "there"`, raises `UndefinedFunctionError` on a `%User{}`, so every welcome email crashes inside the spawned process and nobody sees it. `User` also has no `name` field; the struct built on line 22 has `nickname`, which is never `nil` because line 19 defaults it to the email, so `|| "there"` is dead. Fix: `user.nickname`.

11. **Do not pipe into an anonymous function call.** Line 55, `greeting |> (fn text -> text <> " Enjoy your account." end).()`, is one string in two steps. Fix: `"Hi #{user.nickname}, welcome! Enjoy your account."`.

12. **Do not pipe a single step.** Line 12, `email = params["email"] |> String.downcase()`. Fix: `String.downcase(params["email"])`, which in the improved version becomes `update_change(:email, &String.downcase/1)`.

13. **Use `and` when the operands are booleans.** Line 21, `if is_binary(email) && age >= 18 do`, has two boolean operands, so `and` documents and checks that. The check itself is replaced by `cast/3` and `validate_number/3` in the fix.

14. **Keep functions short and at one level of detail.** `import_user/2` nests `if` inside `if` inside `case` inside `if` inside `try`, four levels deep, with `{:error, :invalid}` repeated on lines 37, 40 and 43. Fix: a public function that reads as build changeset, insert, notify, with the changeset rules in `import_changeset/1` and the nickname default in `put_default_nickname/1`.

15. **Comments explain why; documentation goes in `@moduledoc` and `@doc`.** Lines 2, 5, 7 and 48 (`# This module imports users...`, `# Import a single user...`, `# Get the role from params`, `# send the email`) restate the code or stand in for docs. Fix: move the first two into `@moduledoc` and `@doc` with an `## Options` section, delete the other two. The comment on line 11 explains a reason the code cannot show and stays.

16. **Add specs; name magic numbers with module attributes.** `import_user/2` is public with no `@spec`, and `120` and `18` appear bare on lines 15 and 21. Fix: `@spec import_user(params(), keyword()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}`, `@min_age 18`, `@max_age 120`.

17. **Open a module with `use`, `import`, `alias`, `require`, in that order; put every module under the application namespace.** Line 49 calls a bare `Mailer`, outside the `Accounts` namespace every other module here uses. Fix: `alias Accounts.Mailer`, listed with the other aliases after `import Ecto.Changeset`.

## Improved code

Formatted with `mix format --check-formatted` and compiled with no warnings on Elixir 1.20.3 against Ecto 3.12 stubs. In that run, `%{"email" => "A@B.com", "age" => "200", "role" => "admin"}` produced the changes `%{email: "a@b.com", age: 120, nickname: "a@b.com", role: :admin}`; a row missing `role` with age `12` returned errors on both fields; `role: "root"` returned `"is invalid"`.

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  import Ecto.Changeset

  alias Accounts.Mailer
  alias Accounts.Repo
  alias Accounts.User

  @min_age 18
  @max_age 120

  @type params :: %{optional(String.t()) => String.t()}

  @doc """
  Imports a single user from string-keyed `params`.

  `"email"`, `"age"` and `"role"` are required. `"nickname"` defaults to
  the email address. Ages above #{@max_age} are stored as #{@max_age}.

  Returns `{:error, changeset}` when a field is missing or invalid, or
  when a user with the same email already exists.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  @spec import_user(params(), keyword()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    case Repo.insert(import_changeset(params)) do
      {:ok, user} ->
        if opts[:notify], do: send_welcome(user)
        {:ok, user}

      {:error, _changeset} = error ->
        error
    end
  end

  defp import_changeset(params) do
    %User{}
    |> cast(params, [:email, :age, :role, :nickname])
    |> validate_required([:email, :age, :role])
    # The provider lowercases addresses before its uniqueness check, so match it here
    |> update_change(:email, &String.downcase/1)
    |> update_change(:age, &min(&1, @max_age))
    |> validate_number(:age, greater_than_or_equal_to: @min_age)
    |> put_default_nickname()
    |> unique_constraint(:email)
  end

  defp put_default_nickname(changeset) do
    case fetch_change(changeset, :nickname) do
      {:ok, _nickname} -> changeset
      :error -> put_change(changeset, :nickname, get_change(changeset, :email))
    end
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
