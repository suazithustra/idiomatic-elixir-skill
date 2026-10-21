# Review: `Accounts.UserImporter`

## Findings

1. **The age cap never applies.** The code sets `age = 120` inside an `if`, but Elixir variables bound inside `if` do not leak out. A row with age 200 is saved with age 200. The fix is `min(age, 120)`.

2. **Input is turned into atoms.** `String.to_atom(params["role"])` creates a new atom for every distinct role string. Atoms are never garbage-collected, so a file with many made-up roles can exhaust the atom table (the BEAM virtual machine's symbol table) and crash the node. A `nil` role also raises before the `try`, so the `rescue` never sees it. The fix is a fixed map from known role strings to atoms.

3. **The blanket `rescue` hides real failures.** Any exception, including a database outage or a bug in the code, is reported as `{:error, :invalid}`. Callers then cannot tell bad data from a broken system. The fix is to validate input explicitly and let unexpected errors raise.

4. **Insert failures lose their cause.** The `_ ->` branch drops the reason from `Repo.insert/1`. The fix is to match `{:error, _}` on purpose. Returning the changeset would be better, but it changes the return contract, so this version keeps `:insert_failed`.

5. **Welcome emails are probably never sent.** `user[:name]` uses the `Access` syntax (Elixir's key-lookup protocol). Structs do not implement it by default, so this raises. The raise happens inside the spawned process, so the failure is logged and the import still reports success. The `User` struct in this file has no `name` field either. The fix is `user.nickname`, which the import already sets. This assumes `User` does not implement `Access`; check the schema.

6. **`age` is parsed only from strings.** `String.to_integer/1` fails on an integer, so a JSON source that sends `"age": 30` as a number is rejected as invalid. The fix is to accept both integers and strings.

7. **The `:return_id` option changes the return type.** With it set, the function returns a bare id. Otherwise it returns `{:ok, user}`. Callers have to handle both shapes. This version keeps the behavior, but the option should be split into a separate function.

8. **`spawn/1` is an unmanaged process.** A crash is logged but nothing tracks the process. `Task.start/1` gives the same fire-and-forget behavior with standard tooling. A supervised task (`Task.Supervisor.start_child/2`) is better if a supervisor exists.

9. **Documentation and style.** The module uses comments where it should use `@moduledoc` and `@doc`. Several comments restate the code. The pipe into an anonymous function in `welcome_email/1` is unnecessary.

10. **Email is checked after it is used.** `String.downcase/1` runs before the `is_binary/1` check, so a `nil` email crashes and is caught only by the `rescue`. The fix is to check the type first.

## Improved code

Not compiled or run here. The role names (`admin`, `member`, `guest`) are placeholders and must match what the `User` schema accepts.

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV (comma-separated values) or JSON
  (JavaScript Object Notation) source.
  """

  alias Accounts.{Repo, User}

  # Placeholder role names. Must match the values the User schema accepts.
  @roles %{"admin" => :admin, "member" => :member, "guest" => :guest}

  @min_age 18
  @max_age 120

  @doc """
  Imports one user from `params`.

  Options:

    * `:notify` - send a welcome email (default `false`)
    * `:silent` - suppress the welcome email even when `:notify` is set
    * `:return_id` - return the new user's id instead of `{:ok, user}`

  Returns `{:error, :invalid}` for bad input and `{:error, :insert_failed}`
  when the database rejects the row.
  """
  def import_user(params, opts \\ []) do
    with {:ok, email} <- fetch_email(params),
         {:ok, age} <- parse_age(params["age"]),
         {:ok, role} <- parse_role(params["role"]) do
      user = %User{
        email: email,
        age: age,
        role: role,
        nickname: params["nickname"] || email
      }

      insert_user(user, opts)
    end
  end

  defp fetch_email(%{"email" => email}) when is_binary(email) do
    # The provider lowercases addresses before its uniqueness check, so match it here
    {:ok, String.downcase(email)}
  end

  defp fetch_email(_params), do: {:error, :invalid}

  defp parse_age(age) when is_integer(age), do: validate_age(age)

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {value, ""} -> validate_age(value)
      _ -> {:error, :invalid}
    end
  end

  defp parse_age(_age), do: {:error, :invalid}

  defp validate_age(age) when age >= @min_age, do: {:ok, min(age, @max_age)}
  defp validate_age(_age), do: {:error, :invalid}

  defp parse_role(role) do
    case Map.fetch(@roles, role) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, :invalid}
    end
  end

  defp insert_user(user, opts) do
    case Repo.insert(user) do
      {:ok, user} ->
        if opts[:notify] && !opts[:silent], do: send_welcome(user)

        if opts[:return_id], do: user.id, else: {:ok, user}

      {:error, _reason} ->
        {:error, :insert_failed}
    end
  end

  defp send_welcome(user) do
    Task.start(fn -> Mailer.deliver(welcome_email(user)) end)
  end

  defp welcome_email(user) do
    name = user.nickname || "there"
    "Hi #{name}, welcome! Enjoy your account."
  end
end
```
