# Review: `Accounts.UserImporter`

Findings are ordered by severity. Line numbers refer to `code-review-input.ex`.

## Findings

1. **Any import row can grant itself any role, and enough rows can crash the server.** `String.to_atom(params["role"])` (line 8) turns untrusted text into an atom. Atoms are never garbage-collected, so a file with enough distinct role values exhausts the atom table and takes down the whole BEAM (the Erlang virtual machine), and a row with `"role": "admin"` creates an admin. The call also sits outside the `try`, so a missing role raises instead of returning an error. Fix: map allowed role strings to atoms through a fixed allow-list (`@importable_roles` below). The list in the code is a placeholder; fill in the real roles and leave privileged ones out, since an external file should not be able to create admins.

2. **Welcome emails are never sent.** `welcome_email/1` reads `user[:name]` (line 53), but structs do not support bracket access, so it raises `UndefinedFunctionError` every time. It runs inside `spawn`, so the import still reports success and the failure only appears in the logs. Fix: read the field directly. The code below uses `user.nickname`, which the importer always sets.

3. **The age cap does nothing.** `age = 120` inside the `if` (line 16) creates a new variable that is discarded when the `if` ends, so an age of 150 is stored as 150. The compiler warns about this. Fix: `min(age, 120)`.

4. **Every JSON row with a numeric age is rejected.** JSON decoders return `25`, not `"25"`, and `String.to_integer/1` raises on an integer, which the `rescue` turns into `{:error, :invalid}`. Fix: accept integers as they are and parse strings with `Integer.parse/1`.

5. **Database outages and code bugs are reported as bad input.** `rescue _ ->` (line 43) catches every exception, including a lost database connection, and returns `{:error, :invalid}`. Callers will discard rows that should be retried, and bugs in this module stay hidden. Fix: check each field with pattern matching in a `with` chain and remove the `rescue`, so only real input problems become `{:error, reason}`.

6. **Two imports of the same email at the same time can both succeed.** The code looks up the email (line 24) and inserts afterwards; another process can insert in between (a time-of-check to time-of-use race). It also inserts a bare struct, which skips any validation in `User`. Fix: insert through a changeset with `unique_constraint(:email)`, so the database's unique index rejects the duplicate and `Repo.insert/1` returns `{:error, changeset}`. This needs a unique index on `users.email`. If `User` already has a changeset function with validations, use it in place of `change/2`.

7. **Every failure looks the same.** A missing email, an under-age user, a duplicate and a bad role all return `{:error, :invalid}`, and an insert failure discards the changeset that says why (line 34). Whoever handles a failed row cannot tell what to fix. Fix: return a specific reason per check, and the changeset from a failed insert.

8. **The return shape depends on an option.** With `return_id: true` the function returns a bare id instead of `{:ok, user}` (line 31), so every caller needs two code paths. Fix: always return `{:ok, user}`; callers that need the id match `{:ok, %User{id: id}}`. In the same way, `:notify` and `:silent` (line 27) are two flags for one decision. The code below keeps only `:notify`, so any caller that passes `silent: true` must also stop passing `notify: true`, or it will start sending emails.

9. **Welcome emails run in an unsupervised process.** `spawn/1` (line 49) is not linked or supervised, so failures are lost and emails in progress are dropped on shutdown. Fix: start the task under a `Task.Supervisor`. The code assumes one named `Accounts.TaskSupervisor`, which must be added to the application's supervision tree. Use a job queue such as Oban instead if failed emails must be retried.

10. **The mailer call needs checking.** `Mailer` is not aliased, so it refers to a top-level module named `Mailer`, not `Accounts.Mailer`. `welcome_email/1` also returns a plain string with no recipient, while Swoosh and Bamboo `deliver/1` functions expect an email struct. I left this unchanged because the mailer is not part of this file. Confirm both before relying on the fix in finding 2.

11. **Empty nicknames from CSV are stored as empty.** CSV parsers return `""` for an empty cell, and `"" || email` is `""`, so the email fallback (line 19) never applies to CSV rows. Fix: treat `""` the same as a missing value.

12. **Dead code, an awkward idiom and comments that repeat the code.** `is_binary(email)` (line 21) is always true after `String.downcase/1`. The anonymous function piped into `.()` (line 55) is string concatenation written the long way; use interpolation. Comments such as "Get the role from params" and "send the email" restate the next line. Fix: remove the check and those comments, move the module description into `@moduledoc`, and add `@doc` and `@spec`. The comment explaining why emails are lowercased stays.

## Verification

I ran the original code's suspect lines in Elixir 1.20.3. `String.to_integer(25)` and `String.to_atom(nil)` both raise `ArgumentError`, bracket access on a struct raises `UndefinedFunctionError`, and the age-cap pattern leaves 150 unchanged and triggers an "unused variable" warning. I compiled the improved module against stub versions of `Ecto.Changeset`, `Repo`, `User` and `Mailer` and ran 9 tests covering valid input, string and integer ages, the age cap, each error reason, the nickname fallback, a duplicate email and the welcome email. All 9 passed, and `mix format --check-formatted` passed. It has not been run against a real database or mailer.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  import Ecto.Changeset, only: [change: 2, unique_constraint: 2]

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  # Roles an import file may assign. Replace with the real list and keep privileged roles out.
  @importable_roles %{"member" => :member}

  @doc """
  Imports one user from string-keyed params.

  Returns `{:ok, user}`, or `{:error, reason}` where `reason` is an atom naming the
  invalid field, or the changeset from a failed insert (for example, a duplicate email).

  ## Options

    * `:notify` - send a welcome email after the user is created. Defaults to `false`.
  """
  @spec import_user(map(), keyword()) ::
          {:ok, %User{}}
          | {:error, :invalid_email | :invalid_age | :underage | :invalid_role}
          | {:error, Ecto.Changeset.t()}
  def import_user(params, opts \\ []) do
    with {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         {:ok, role} <- parse_role(params["role"]),
         {:ok, user} <- insert_user(email, age, role, nickname(params["nickname"], email)) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  # The provider lowercases addresses before its uniqueness check, so match it here.
  defp parse_email(email) when is_binary(email) and email != "",
    do: {:ok, String.downcase(email)}

  defp parse_email(_email), do: {:error, :invalid_email}

  # CSV gives "25", JSON gives 25.
  defp parse_age(age) when is_integer(age), do: check_age(age)

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {age, ""} -> check_age(age)
      _ -> {:error, :invalid_age}
    end
  end

  defp parse_age(_age), do: {:error, :invalid_age}

  defp check_age(age) when age < @min_age, do: {:error, :underage}
  defp check_age(age), do: {:ok, min(age, @max_age)}

  defp parse_role(role) do
    case Map.fetch(@importable_roles, role) do
      {:ok, role} -> {:ok, role}
      :error -> {:error, :invalid_role}
    end
  end

  # CSV parsers return "" for an empty cell.
  defp nickname(nickname, _email) when is_binary(nickname) and nickname != "", do: nickname
  defp nickname(_nickname, email), do: email

  # Needs a unique index on users.email; it turns a duplicate into {:error, changeset}.
  defp insert_user(email, age, role, nickname) do
    %User{}
    |> change(email: email, age: age, role: role, nickname: nickname)
    |> unique_constraint(:email)
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
