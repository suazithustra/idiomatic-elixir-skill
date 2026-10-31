# Review of `Accounts.UserImporter`

A crafted import file can crash the whole application, and welcome emails are never sent. The age cap also does nothing, JSON (JavaScript Object Notation) imports with numeric ages are rejected, and the duplicate-email check can be bypassed.

The improved code at the end fixes everything except finding 12. It needs the steps under "Required before merging" before it can ship. Line numbers refer to `code-review-input.ex`.

## Findings, most severe first

1. **Line 8: a file can crash the application or grant any role.** `String.to_atom/1` turns each role in the file into an atom (one of Elixir's named constants). Atoms are never freed, so enough different role values fill the atom table and stop the Erlang virtual machine. The role is also not checked, so a file can set `admin`. The fix is a fixed list, `@roles`, that maps allowed strings to atoms.

2. **Line 53: no welcome email is ever sent.** `user[:name]` crashes because `[]` does not work on structs. The crash happens in a background process, so the import still reports success. The fix uses `user.nickname`, the only name-like field this module sets. When no nickname is given, the greeting shows the email address.

3. **Lines 24-25: the same email can be imported twice.** The code looks up the email and then inserts, so two imports running at once can both pass the lookup. Without a unique index (a database rule allowing each email once) this creates duplicate accounts. With one, the insert raises and the error is reported as `:invalid`. The fix removes the lookup and adds `unique_constraint(:email)` to a changeset (Ecto's record of a proposed change), so the database decides and the loser gets `{:error, :email_taken}`.

4. **Lines 15-17: the age cap does nothing.** `age = 120` inside the `if` only applies within that block, so an age of 200 is stored as 200. The compiler warns about this. The fix is `min(age, @max_age)`.

5. **Line 13: JSON users with numeric ages are all rejected.** The module takes CSV (comma-separated values) and JSON, but `String.to_integer/1` accepts only strings, so an age of `30` raises and comes back as `:invalid`. The fix is `parse_age/1`, which accepts both forms.

6. **Lines 42-43: `rescue _` hides outages and bugs.** A database outage or a coding mistake is reported as an invalid row, so a failed import looks like bad data. The fix removes `try`/`rescue`. The parsing helpers handle bad input directly, and unexpected errors now surface.

7. **Line 8: a missing role crashes the import.** This line sits outside the `try`, so a row with no role raises while every other bad row returns an error. The fix returns `{:error, :invalid_role}`.

8. **Lines 19 and 21: blank CSV cells are stored as real values.** Empty strings are truthy in Elixir, so a blank nickname stays `""`, and a blank email creates a user with no address. The `is_binary(email)` check can never fail, because `String.downcase/1` has already raised on non-strings. The fix treats a blank nickname as missing and requires an email of the form `x@y`.

9. **Lines 37, 40 and 43: callers cannot tell why a row failed.** A duplicate, a bad age and a malformed email all return `{:error, :invalid}`, so a re-run cannot separate expected duplicates from bad data. The fix returns `:invalid_role`, `:invalid_email`, `:invalid_age` or `:email_taken`.

10. **Line 31: `:return_id` changes the return shape.** Success is either `{:ok, user}` or a bare id, so callers cannot handle results in one way. The fix removes the option and always returns `{:ok, user}`.

11. **Line 49: background email runs in a bare `spawn`.** Nothing supervises the process, and it is cut off when the application shuts down. The fix uses `Task.Supervisor.start_child/2`. This does not retry a failed email. If lost emails matter, I would use Oban (a database-backed job queue) and enqueue the email in the same transaction as the insert.

12. **Lines 49 and 52-56: the mail call looks wrong, and I did not fix it.** `welcome_email/1` returns plain text with no recipient, so `Mailer.deliver/1` has no address to send to. `Mailer` is also not aliased, so it means top-level `Mailer` rather than `Accounts.Mailer`. `Mailer` is not in this file, so I kept the call as it was. I would build a real email with `to: user.email`. Until this is settled, finding 2's fix may still not get email to users.

13. **Line 27: `:silent` only cancels `:notify`.** The two options overlap. I kept `:silent`, because removing it would make any caller passing both start sending emails with no error. Remove it once callers are checked.

14. **Readability.** Four levels of nesting became a flat `with`. The anonymous function in a pipe on line 55 became plain string interpolation. Comments that repeated the code are gone, and `@moduledoc`, `@doc` and `@spec` are added. I kept the comment from line 11 unchanged, because it explains a reason the code cannot show.

## Required before merging

1. Replace the roles in `@roles`. `member` and `viewer` are placeholders, because the real list is not in this file. Leave out any role an import should not grant.
2. Confirm a unique index on `users.email` named `users_email_index`, or pass its name to `unique_constraint`. Without an index the new code creates duplicates every time, because the lookup is gone.
3. Add `{Task.Supervisor, name: Accounts.TaskSupervisor}` to the application's supervision tree. Without it, imports using `:notify` crash after the user is inserted.
4. Update callers that pass `return_id: true` or match `{:error, :invalid}` or `{:error, :insert_failed}`.
5. Resolve finding 12.

## What was tested

Running the original against stubs confirmed findings 2, 4, 5, 7, 8 and 10, including that the crash in finding 2 happens on line 53. The other findings come from reading the code, and findings 1 and 3 in particular were not reproduced.

The improved module passed 20 checks using real Ecto on SQLite, with a stubbed `Mailer` and a stand-in `User` schema. That includes 8 simultaneous imports of one email, which gave 1 success and 7 `:email_taken`. It has not been run on your real `User`, `Repo` or `Mailer`, or on Postgres.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV/JSON source.

  Relies on a unique database index on `users.email` to reject duplicates.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  # Input is untrusted, so roles are looked up here instead of being converted to atoms.
  # List only the roles an import may grant.
  @roles %{"member" => :member, "viewer" => :viewer}

  @type error :: :invalid_role | :invalid_email | :invalid_age | :email_taken

  @doc """
  Imports a single user from string-keyed `params`.

  Ages above #{@max_age} are stored as #{@max_age}. Ages below #{@min_age} are rejected.

  ## Options

    * `:notify` - send a welcome email once the user is created
    * `:silent` - suppress the welcome email even if `:notify` is set

  """
  @spec import_user(map(), keyword()) :: {:ok, %User{}} | {:error, error()}
  def import_user(params, opts \\ []) do
    with {:ok, role} <- parse_role(params["role"]),
         {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         nickname = parse_nickname(params["nickname"], email),
         {:ok, user} <- insert_user(%{email: email, age: age, role: role, nickname: nickname}) do
      if opts[:notify] && !opts[:silent], do: send_welcome(user)
      {:ok, user}
    end
  end

  defp parse_role(role) do
    case Map.fetch(@roles, role) do
      {:ok, role} -> {:ok, role}
      :error -> {:error, :invalid_role}
    end
  end

  defp parse_email(email) when is_binary(email) do
    # The provider lowercases addresses before its uniqueness check, so match it here
    email = String.downcase(email)

    if email =~ ~r/\A[^@\s]+@[^@\s]+\z/, do: {:ok, email}, else: {:error, :invalid_email}
  end

  defp parse_email(_email), do: {:error, :invalid_email}

  # CSV ages arrive as strings, JSON ages as integers.
  defp parse_age(age) when is_integer(age), do: check_age(age)

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {age, ""} -> check_age(age)
      _ -> {:error, :invalid_age}
    end
  end

  defp parse_age(_age), do: {:error, :invalid_age}

  defp check_age(age) when age >= @min_age, do: {:ok, min(age, @max_age)}
  defp check_age(_age), do: {:error, :invalid_age}

  # A blank CSV cell arrives as "", which `||` would keep because it is truthy.
  defp parse_nickname(nickname, _email) when is_binary(nickname) and nickname != "", do: nickname
  defp parse_nickname(_nickname, email), do: email

  defp insert_user(attrs) do
    changeset =
      %User{}
      |> Ecto.Changeset.change(attrs)
      |> Ecto.Changeset.unique_constraint(:email)

    case Repo.insert(changeset) do
      {:ok, user} -> {:ok, user}
      # The unique constraint is the only check on this changeset.
      {:error, _changeset} -> {:error, :email_taken}
    end
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
