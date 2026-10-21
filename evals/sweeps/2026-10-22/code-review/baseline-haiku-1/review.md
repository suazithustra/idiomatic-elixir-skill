# Review: `Accounts.UserImporter`

## Findings

1. **The role string is turned into an atom from untrusted input.** `String.to_atom/1` creates a new atom for every distinct value. Atoms are never garbage collected, so a file with many different role strings can crash the VM. A missing `"role"` key also raises before the `try` block, so it crashes the caller instead of returning an error. Fix: check the role against a fixed list and return `{:error, :invalid}` when it is not on the list.

2. **The age cap of 120 never applies.** In Elixir, a variable rebound inside an `if` does not change the variable outside it. So `age` stays at 150 after the `if`, and 150 is saved. Fix: `min(age, 120)`.

3. **Welcome emails never send.** `user[:name]` uses the Access protocol, which Ecto structs do not implement, so the call raises. The raise happens inside a `spawn`ed process, so nothing reports it and the email is silently dropped. Fix: build the greeting from `user.nickname`, which the code above always sets.

4. **Unsupervised processes lose errors.** `spawn/1` starts a process that no supervisor watches. Any crash in mail delivery goes unlogged. Fix: use `Task.start/1` at minimum. If the app has a `Task.Supervisor`, use `Task.Supervisor.start_child/2` so failures are supervised.

5. **A catch-all `rescue` hides bugs and drives validation.** `rescue _ ->` turns any exception into `{:error, :invalid}`, including database and code bugs. Input checks run through `String.downcase/1` and `String.to_integer/1` and rely on the rescue to catch bad types. Fix: check each field with its own function clause and remove the `try`.

6. **The return value changes shape.** With `return_id: true` the function returns a bare integer. Otherwise it returns `{:ok, user}`. Callers that match on `{:ok, _}` break when the option is set. Fix: return `{:ok, id}` in that case. Callers that use the option must be updated.

7. **Insert failures lose their reason.** `_ -> {:error, :insert_failed}` discards the changeset that holds the validation errors. Fix: keep the changeset in the error tuple, or log it.

8. **Comments restate the code.** Lines such as "Get the role from params" add nothing. The module comment and the one on the email lowercasing explain why and can stay.

## Assumptions

- The role list `@roles` is a placeholder. Replace it with the application's real roles.
- The welcome email is built from `nickname`, because the `User` schema was not provided and `nickname` is the only name field in the code shown.
- The improved code has not been compiled or run.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc "Imports users from an external CSV or JSON source."

  alias Accounts.{Repo, User}

  # Placeholder: replace with the application's real roles.
  @roles ~w(admin editor member)a
  @min_age 18
  @max_age 120

  @doc """
  Imports one user from a map of params.

  Returns `{:ok, user}`, or `{:ok, id}` when `return_id: true` is passed.
  Returns `{:error, :invalid}` for bad input and `{:error, :insert_failed}`
  when the database rejects the record.

  Options:
    * `:notify` - send a welcome email (default `false`)
    * `:silent` - suppress the welcome email even when `:notify` is set
    * `:return_id` - return the new user's id instead of the struct
  """
  def import_user(params, opts \\ []) do
    with {:ok, email} <- fetch_email(params),
         {:ok, age} <- fetch_age(params),
         {:ok, role} <- fetch_role(params),
         {:ok, user} <- insert_user(params, email, age, role) do
      if opts[:notify] && !opts[:silent] do
        send_welcome(user)
      end

      if opts[:return_id], do: {:ok, user.id}, else: {:ok, user}
    end
  end

  # The provider lowercases addresses before its uniqueness check, so match it here.
  defp fetch_email(%{"email" => email}) when is_binary(email) do
    {:ok, String.downcase(email)}
  end

  defp fetch_email(_params), do: {:error, :invalid}

  defp fetch_age(%{"age" => age}) when is_binary(age) do
    case Integer.parse(age) do
      {age, ""} when age >= @min_age -> {:ok, min(age, @max_age)}
      _ -> {:error, :invalid}
    end
  end

  defp fetch_age(_params), do: {:error, :invalid}

  # Matches against the known atoms, so input never creates new atoms.
  defp fetch_role(%{"role" => role}) when is_binary(role) do
    case Enum.find(@roles, &(Atom.to_string(&1) == role)) do
      nil -> {:error, :invalid}
      role -> {:ok, role}
    end
  end

  defp fetch_role(_params), do: {:error, :invalid}

  defp insert_user(params, email, age, role) do
    user = %User{
      email: email,
      age: age,
      role: role,
      nickname: params["nickname"] || email
    }

    case Repo.insert(user) do
      {:ok, user} -> {:ok, user}
      {:error, _changeset} -> {:error, :insert_failed}
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
