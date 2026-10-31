# Review: `Accounts.UserImporter`

## Findings

1. **Age cap does nothing.** The `if age > 120 do age = 120 end` block never changes the outer `age`, because variables bound inside an `if` do not leave it in Elixir. A user aged 200 is stored as 200. Fix: `min(age, 120)`.

2. **Welcome emails are never sent.** `welcome_email/1` reads `user[:name]`. The `User` struct does not implement the Access behaviour (the `[]` lookup), so this raises inside the spawned process, and the failure is only logged. The import also never sets a `name` field. Fix: use `user.nickname`, which is always set (it falls back to the email).

3. **Atom leak from external input.** `String.to_atom(params["role"])` creates a new atom for every distinct input string. Atoms are never garbage collected, so a stream of bad input can exhaust the atom table and crash the VM (Erlang virtual machine). A `nil` role also crashes here. Fix: `String.to_existing_atom/1`, or better, an explicit allowlist of valid roles.

4. **Blanket `try`/`rescue` hides bugs.** Every exception, including database failures and typos, becomes `{:error, :invalid}`. The caller cannot tell bad input from a broken system. Fix: parse each field explicitly and chain the steps with `with`.

5. **The `is_binary(email)` check is dead code.** `String.downcase(nil)` raises before the check runs, and the rescue turns that into `{:error, :invalid}`. The result is right by accident. Fix: match on a binary email in the function head.

6. **Age parsing fails on integer input.** `String.to_integer/1` only accepts strings. A JSON source that sends `"age": 25` as a number raises and is rejected. Fix: accept integers directly and parse strings with `Integer.parse/1`.

7. **Duplicate check has a race.** The `Repo.get_by` check and the `Repo.insert` are separate steps, so two imports of the same email can both pass the check. Fix: add a unique index on `email` in the database, then handle the constraint error from the insert. The code below keeps the check to preserve current behaviour; the index is still needed. This is a migration, so I did not write it.

8. **Unsupervised `spawn`.** A crash in the welcome email process is logged but not supervised. `Task.start/1` gives the same behaviour with clearer intent. For retries or back-pressure, use a `Task.Supervisor`.

9. **Inconsistent return type.** With `return_id: true` the function returns a bare id. Otherwise it returns `{:ok, user}`. Callers must match on both shapes. The code below keeps this behaviour and documents it. Changing it would break callers, so I left it for you to decide.

10. **Style.** Several comments restate the code. The `welcome_email/1` pipe through an anonymous function is hard to read, and string interpolation does the same job. The module has no `@moduledoc`.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports a single user from an external CSV or JSON source.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports one user from `params`.

  Returns `{:ok, user}`, or the new user's id when `return_id: true` is set.
  Returns `{:error, :invalid}` for bad input or a duplicate email, and
  `{:error, :insert_failed}` when the database rejects the insert.

  Options:

    * `:notify` - send a welcome email (default `false`)
    * `:silent` - skip the welcome email even when `:notify` is set
    * `:return_id` - return the id instead of `{:ok, user}`
  """
  def import_user(params, opts \\ []) do
    with {:ok, email} <- fetch_email(params),
         {:ok, age} <- parse_age(params["age"]),
         :ok <- check_age(age),
         {:ok, role} <- parse_role(params["role"]),
         :ok <- check_unique(email) do
      user = %User{
        email: email,
        age: min(age, @max_age),
        role: role,
        nickname: params["nickname"] || email
      }

      insert(user, opts)
    end
  end

  defp fetch_email(%{"email" => email}) when is_binary(email),
    do: {:ok, String.downcase(email)}

  defp fetch_email(_), do: {:error, :invalid}

  defp parse_age(age) when is_integer(age), do: {:ok, age}

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :invalid}
    end
  end

  defp parse_age(_), do: {:error, :invalid}

  defp check_age(age) when age >= @min_age, do: :ok
  defp check_age(_), do: {:error, :invalid}

  # Fails on atoms that do not exist yet, so unknown roles cannot grow the atom table.
  defp parse_role(role) when is_binary(role) do
    {:ok, String.to_existing_atom(role)}
  rescue
    ArgumentError -> {:error, :invalid}
  end

  defp parse_role(_), do: {:error, :invalid}

  defp check_unique(email) do
    if Repo.get_by(User, email: email), do: {:error, :invalid}, else: :ok
  end

  defp insert(user, opts) do
    case Repo.insert(user) do
      {:ok, user} ->
        if opts[:notify] && !opts[:silent], do: send_welcome(user)

        if opts[:return_id], do: user.id, else: {:ok, user}

      {:error, _changeset} ->
        {:error, :insert_failed}
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

## Assumptions to check

- `role` values must already exist as atoms (for example, through an `Ecto.Enum` field or a pattern match elsewhere in the code). If they do not, every import fails with `{:error, :invalid}`. An explicit allowlist is the safer long-term choice.
- `Mailer` was not aliased in the original. I left it as is.
- `User` has no `name` field, so the welcome email uses `nickname`. If `User` does have a `name`, use that instead.
