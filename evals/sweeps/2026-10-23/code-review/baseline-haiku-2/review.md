# Review: Accounts.UserImporter

## Findings

1. The role string from the import file is converted to an atom (a permanent Elixir name), with no check on its value (line 8). Atoms are never garbage-collected, so a file with many distinct role strings can exhaust memory, and any role name, including "admin", is accepted. A `nil` role also crashes here. Fix: map an allowed list of role names to atoms and reject everything else.

2. The age cap never applies (lines 15–17). A variable set inside an `if` block does not change the variable outside it, so `age = 120` is discarded and the value is never read. Users over 120 are saved with their original age. Fix: `min(value, @max_age)`.

3. The blanket `rescue _ ->` (lines 42–43) turns every error into `{:error, :invalid}`, including database failures and bugs in this code, so real faults look like bad rows. It also serves as normal input checking: `String.to_integer/1` (line 13) raises on bad text and on integers that come from JSON, and `String.downcase/1` (line 12) raises on a missing email. The `is_binary(email)` check (line 21) runs after that crash point and does nothing useful. Fix: validate each field with functions that return `{:ok, value}` or `{:error, reason}`, and keep `rescue` out.

4. The welcome email never sends. Line 53 calls `user[:name]`. `%User{}` is a struct (a fixed-shape map), and structs do not support bracket access, so the call raises. It raises inside the spawned process, so the caller never sees it. The field is also wrong: the struct has `nickname`, not `name`. Fix: use `user.nickname`.

5. The welcome email runs in a process nothing supervises (line 49, `spawn/1`). If it crashes, no supervisor restarts or tracks it. Fix: `Task.start/1`, which at least logs the crash, or `Task.Supervisor.start_child/2` if the app already has a task supervisor.

6. The return value has no consistent shape. With `:return_id` set, the function returns a bare integer (line 31). Otherwise it returns `{:ok, user}`. Errors use two different atoms, `:invalid` and `:insert_failed`. Callers cannot match on one pattern. Fix: always return `{:ok, user}` or `{:error, reason}`, and let callers read `.id`. This changes the API for any caller that passes `:return_id`.

7. The duplicate-email check is a race (lines 24–25). The code checks with `Repo.get_by/2`, then inserts. Two imports of the same address at the same time can both pass the check. Fix: a unique index on the email column, a changeset with `unique_constraint(:email)`, and mapping that error to `{:error, :invalid}`. The rewrite below keeps the check, so this race is still present there.

8. The nesting is hard to follow and some lines add nothing. Four levels of `if` and `case` bury the success path. Line 55 wraps a string concatenation in an anonymous function for no reason. Comments such as "# send the email" restate the code. Fix: a `with` chain, as below.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external source of comma-separated values (CSV) or
  JavaScript Object Notation (JSON) records.
  """

  alias Accounts.{Repo, User}

  # Replace these with the roles your application defines. Any other role is rejected.
  @roles %{"member" => :member, "editor" => :editor, "admin" => :admin}
  @min_age 18
  @max_age 120

  @doc """
  Imports one user. Returns `{:ok, user}` or `{:error, reason}`.

  Options:
    * `:notify` - send a welcome email (default `false`)
    * `:silent` - suppress the welcome email even when `:notify` is set
  """
  def import_user(params, opts \\ []) do
    with {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         {:ok, role} <- parse_role(params["role"]),
         :ok <- ensure_unique_email(email),
         {:ok, user} <- insert_user(email, age, role, params["nickname"]) do
      maybe_send_welcome(user, opts)
      {:ok, user}
    end
  end

  defp parse_email(email) when is_binary(email), do: {:ok, String.downcase(email)}
  defp parse_email(_), do: {:error, :invalid}

  defp parse_age(age) when is_integer(age) and age >= @min_age, do: {:ok, min(age, @max_age)}

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {value, ""} -> parse_age(value)
      _ -> {:error, :invalid}
    end
  end

  defp parse_age(_), do: {:error, :invalid}

  defp parse_role(role) do
    case Map.fetch(@roles, role) do
      {:ok, role} -> {:ok, role}
      :error -> {:error, :invalid}
    end
  end

  defp ensure_unique_email(email) do
    case Repo.get_by(User, email: email) do
      nil -> :ok
      _user -> {:error, :invalid}
    end
  end

  defp insert_user(email, age, role, nickname) do
    user = %User{email: email, age: age, role: role, nickname: nickname || email}

    case Repo.insert(user) do
      {:ok, user} -> {:ok, user}
      {:error, _changeset} -> {:error, :insert_failed}
    end
  end

  defp maybe_send_welcome(user, opts) do
    if Keyword.get(opts, :notify, false) && !Keyword.get(opts, :silent, false) do
      send_welcome(user)
    end
  end

  defp send_welcome(user) do
    Task.start(fn -> Mailer.deliver(welcome_email(user)) end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

## Behavior changes

- The return shape is always `{:ok, user}` or `{:error, reason}`. The `:return_id` option is gone. Callers that need the id should read `user.id`.
- Only the roles in `@roles` are accepted. Replace the placeholder list with your real roles.
- Ages given as JSON integers are now accepted. Previously they were rejected.
- The age cap of 120 now takes effect, as the original code intended.
- The welcome email uses the nickname. It previously tried to read a `name` field and crashed, so it never sent.
- Finding 7 (the duplicate-email race) is not fixed in this version. It needs a unique index and a changeset.
