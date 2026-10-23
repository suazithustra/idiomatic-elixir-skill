# Review of `code-review-input.ex` (`Accounts.UserImporter`)

The importer has three bugs that change what it does: the age cap never applies, the welcome email is never sent, and any string in the `role` column becomes a permanent atom, so a bad import file can crash the node. It also hides every failure behind `{:error, :invalid}`. The fix is to validate the input with an Ecto changeset and let the rest of the function shrink around it. Findings are ordered by severity. Line numbers refer to `code-review-input.ex`.

## Findings

1. **The age cap never applies.** Rule: *Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it.* Line 16, `age = 120`, inside `if age > 120 do` on line 15, binds a new `age` that exists only inside the `if`. A user aged 150 is stored as 150, and the compiler warns that the inner `age` is unused. Fix: use the result. The improved version does this in the changeset with `update_change(:age, &min(&1, @max_age))`.

2. **The welcome email is never sent.** Rule: *structs do not implement `Access`.* Line 53, `name = user[:name] || "there"`, raises `UndefinedFunctionError` because `user` is a `%User{}` struct. The error happens inside the spawned process, so the caller never sees it and the email is dropped, leaving only a crash report in the log. Fix: `user.name || "there"`. Note that this importer never sets `name`, so every imported user is greeted "Hi there". If `User` has no `name` field, greet by `user.nickname` instead, which this importer always sets.

3. **The role column can exhaust the atom table.** Rule: *Convert external strings to atoms with explicit clauses.* Line 8, `role = String.to_atom(params["role"])`, creates a new atom for every distinct role string in the file. Atoms are never garbage-collected and the VM (virtual machine) has a fixed limit of 1,048,576 by default, so a broken or hostile file can crash the node. The line also sits outside the `try`, so a row with no role raises `ArgumentError` to the caller. Fix: declare `field :role, Ecto.Enum, values: [...]` in `User` and cast `:role` in the changeset. An unknown role string then becomes a changeset error.

4. **The `rescue` hides every failure, including bugs.** Rule: *Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs.* Lines 42–43, `rescue` and `_ -> {:error, :invalid}`, wrap the whole body to turn `String.to_integer/1` and `String.downcase(nil)` failures into a tuple. They also catch database outages, unique-index violations and coding errors and report all of them as `:invalid`. Fix: remove the `try`. `cast/3` converts `"42"` to `42` and records `"abc"` as a field error without raising.

5. **Input is checked by hand and inserted as a bare struct.** Rule: *Validate input with changesets* (`references/ecto-phoenix.md`), and *Parse external data into structs where it enters the system*. Line 22, `user = %User{email: email, age: age, role: role, nickname: nickname}`, is built from fields read with `params["..."]` (lines 8, 12, 13) and checked with an `if` on line 21. `Repo.insert/1` inserts a struct as given, with no validation. Fix: `cast/3`, `validate_required/2` and `validate_number/3` in a changeset, then `Repo.insert/1` on the changeset.

6. **The duplicate-email check can be bypassed.** Rule: *Declare database constraints in the changeset (`unique_constraint/3`)*. Line 24, `if Repo.get_by(User, email: email) == nil do`, looks the user up and then inserts. Two imports of the same address can both see `nil`. The second insert then either raises on the unique index, which line 43 reports as `:invalid`, or, without an index, creates a duplicate user. Fix: `unique_constraint(:email)` in the changeset, backed by a unique index on `users.email`. A duplicate then comes back as `{:error, changeset}`.

7. **The insert error is thrown away.** Rule: *Match every expected shape and let unexpected ones crash.* Lines 33–34, `_ ->` and `{:error, :insert_failed}`, discard the changeset that says what failed. Together with the three `{:error, :invalid}` returns, the caller cannot tell a duplicate email from an underage user. Fix: return the changeset with `{:error, _changeset} = error -> error`.

8. **An option changes the return type.** Rule: *Give each function one return shape.* Line 31, `if opts[:return_id], do: user.id, else: {:ok, user}`, returns a bare integer in one mode and a tuple in the other, and errors are tuples in both. Fix: drop `:return_id`. A caller that wants the ID matches `{:ok, %User{id: id}}`.

9. **Two boolean options overlap.** Rules: *Use one atom-valued field or option instead of overlapping booleans* and *Group related parameters*. Line 27, `if opts[:notify] && !opts[:silent] do`: `:silent` exists only to cancel `:notify`, and `notify: true, silent: true` has no sensible meaning. The options are also never checked, so a misspelled key is ignored. Fix: keep `:notify` alone, check it with `Keyword.validate!(opts, notify: false)`, and document it under `## Options`. The improved version branches on the value with two `maybe_send_welcome/2` clauses, so a non-boolean value fails there.

10. **`&&` and `!` are used on booleans.** Rule: *Use `and`, `or`, `not` when the operands are booleans.* Line 21, `if is_binary(email) && age >= 18 do`, and line 27 combine booleans, so `and` and `not` are the operators to use. The `is_binary(email)` test on line 21 is also always true, because `String.downcase/1` on line 12 has already raised for anything that is not a string. In the improved version `validate_number/3` replaces the check.

11. **The email process is not supervised.** Rule: *Pick the abstraction that matches the job* (`references/processes.md`: fire-and-forget work uses `Task.Supervisor.start_child/2`). Line 49, `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`, starts a process no supervisor knows about, so it is not stopped cleanly at shutdown and does not appear in Observer or LiveDashboard. Fix: `Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> ... end)`, with `{Task.Supervisor, name: Accounts.TaskSupervisor}` added to the application's supervision tree.

12. **The closure copies the whole user into the new process.** Rule: *Send processes only the data they need.* On line 49 the anonymous function captures `user`, so the whole struct is copied into the new process to build one string. Fix: build the message first, `welcome = welcome_email(user)`, and capture only `welcome`.

13. **A pipeline ends in an anonymous function call.** Rule: *Write pipelines that start with a value and read top to bottom.* Line 55, `greeting |> (fn text -> text <> " Enjoy your account." end).()`. Fix: one interpolated string, `"Hi #{name}, welcome! Enjoy your account."`.

14. **A single-step pipe.** Same rule. Line 12, `email = params["email"] |> String.downcase()`. Fix: `String.downcase(email)`. The improved version does this in the changeset with `update_change(:email, &String.downcase/1)`.

15. **`import_user/2` nests four levels deep.** Rule: *Keep functions short and at one level of detail.* Lines 21–41 nest `if`, `if`, `case` and `if` inside a `try`. Fix: `import_user/2` checks its options, calls `insert_user/1`, and passes the result to `maybe_send_welcome/2`. The field rules live in `import_changeset/2`.

16. **Unnamed numbers.** Rule: *Name magic numbers with module attributes.* Line 15, `if age > 120 do`, and line 21, `age >= 18`. Fix: `@max_age 120` and `@min_age 18`.

17. **Comments used as documentation.** Rule: *Comments explain why; documentation goes in `@moduledoc` and `@doc`.* Line 2, `# This module imports users from an external CSV/JSON source`, and line 5, `# Import a single user from the given params`. The options are documented nowhere. Fix: a `@moduledoc`, and a `@doc` with an `## Options` section, followed by a `@spec`.

18. **Comments that repeat the code.** Same rule. Line 7, `# Get the role from params`, and line 48, `# send the email`, say what the next line says. Delete them. Line 11, `# The provider lowercases addresses before its uniqueness check, so match it here`, gives a reason the code cannot show, so it stays.

## Changes callers will notice

Errors are now `{:error, %Ecto.Changeset{}}` instead of `{:error, :invalid}` or `{:error, :insert_failed}`. The `:silent` and `:return_id` options are gone, and passing any option other than `:notify` raises `ArgumentError`. An empty `nickname` now falls back to the email, because `cast/3` treats `""` as missing. The code assumes three things outside this file: `User` declares `role` as an `Ecto.Enum`, `users.email` has a unique index, and `Accounts.TaskSupervisor` is started in the supervision tree.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  import Ecto.Changeset

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from string-keyed `params`.

  Returns `{:ok, user}`, or `{:error, changeset}` when a field is missing or
  invalid, the user is younger than #{@min_age}, or the email is already taken.
  An age above #{@max_age} is stored as #{@max_age}.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  @spec import_user(map(), keyword()) :: {:ok, %User{}} | {:error, Ecto.Changeset.t()}
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    case insert_user(params) do
      {:ok, user} ->
        maybe_send_welcome(user, opts[:notify])
        {:ok, user}

      {:error, _changeset} = error ->
        error
    end
  end

  defp insert_user(params) do
    %User{}
    |> import_changeset(params)
    |> Repo.insert()
  end

  defp import_changeset(user, params) do
    user
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
    case get_field(changeset, :nickname) do
      nil -> put_change(changeset, :nickname, get_field(changeset, :email))
      _nickname -> changeset
    end
  end

  defp maybe_send_welcome(user, true), do: send_welcome(user)
  defp maybe_send_welcome(_user, false), do: :ok

  defp send_welcome(user) do
    welcome = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(welcome) end)
  end

  defp welcome_email(user) do
    name = user.name || "there"
    "Hi #{name}, welcome! Enjoy your account."
  end
end
```

## Verification

The improved module passes `mix format --check-formatted`. It compiled without warnings and ran against Ecto 3 with stub `User`, `Repo` and `Mailer` modules (script in `verify/check.exs`). The results: age 150 is stored as 120, the email is lowercased, a missing nickname falls back to the email, and the welcome email is sent only with `notify: true`. Age 17, age `"abc"`, an unknown role, a missing email and a missing role each return `{:error, changeset}` naming the field, and an unknown option raises `ArgumentError`. The stub `Repo` has no database, so the unique-email constraint was not exercised.
