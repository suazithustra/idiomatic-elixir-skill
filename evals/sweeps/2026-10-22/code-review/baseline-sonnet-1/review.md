# Review: Accounts.UserImporter

## Findings

1. **Bug: the age cap does nothing.** `age = 120` inside `if` only rebinds within the `if` block (Elixir scoping), so ages above 120 pass through unchanged. Fix: `min(age, 120)`.

2. **Security: `String.to_atom/1` on imported data.** Atoms (Erlang's interned symbols) are never garbage collected, so a large file with many distinct roles can crash the VM (virtual machine). It also raises on a missing `"role"` key. Fix: look the role up in a fixed map.

3. **`try/rescue` hides real errors.** It turns every exception (a bad insert, a bug in `send_welcome`, a typo) into `{:error, :invalid}`. It exists only to cover `nil` input and failed integer parsing. Fix: validate explicitly with `Integer.parse/1` and pattern matching, and let unexpected errors crash.

4. **Inconsistent return type.** With `return_id: true` the function returns a bare id; otherwise `{:ok, user}`. Callers can't pattern match on one shape. Fix: always return `{:ok, user}` (callers can use `user.id`). This changes behavior for callers that pass `return_id`.

5. **Error details are discarded.** `_ -> {:error, :insert_failed}` drops the changeset (e.g. a duplicate email), so callers can't report what was wrong. Fix: return `{:error, changeset}`.

6. **Inserting a bare struct skips validation.** `Repo.insert(%User{...})` does no casting or constraint handling, so a unique-index violation raises instead of returning an error. Fix: go through a changeset that calls `unique_constraint(:email)`. This assumes `User.import_changeset/2` exists or is added (not in the input, so I sketched the call).

7. **Bug: `user[:name]` on a struct.** Structs don't implement `Access`, so this raises `UndefinedFunctionError`. Because the call runs inside a `spawn`, the welcome email silently never sends. Fix: `user.name` (or `Map.get/3`), but check that `User` has a `:name` field. The input struct sets `:nickname`, not `:name`, so I used `nickname`.

8. **Unsupervised `spawn`.** A failure is invisible and nothing is retried or tracked. Fix: `Task.Supervisor.start_child/2` under a named supervisor (`Accounts.TaskSupervisor`, which must be in the supervision tree). `Mailer` is also not aliased, so I aliased it.

9. **Dead and awkward logic.**
   - `is_binary(email)` is checked after `String.downcase/1` has already required a binary.
   - `opts[:notify] && !opts[:silent]` can be one option, so I kept only `:notify`. `:silent` is gone; that is another small API change.
   - `welcome_email` pipes into an anonymous function to append a string. Use one interpolated string.
   - `&&`/`!` on booleans: prefer `and`/`not` where values are strictly boolean.

10. **Noise comments.** Comments such as `# Get the role from params` and `# send the email` restate the code. I removed them and kept the one that explains why email is lowercased. Added `@doc` and `@spec`.

11. **Underage and invalid input are indistinguishable.** Both return `{:error, :invalid}`. Now they return `:invalid_age`, `:underage`, `:invalid_role`, and `:invalid_email`.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV/JSON source.
  """

  alias Accounts.{Mailer, Repo, User}

  @roles %{"admin" => :admin, "member" => :member, "guest" => :guest}
  @min_age 18
  @max_age 120

  @type error ::
          :invalid_email
          | :invalid_age
          | :underage
          | :invalid_role
          | Ecto.Changeset.t()

  @doc """
  Imports one user from string-keyed params.

  Options:

    * `:notify` - send a welcome email after a successful insert (default `false`)
  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, error()}
  def import_user(params, opts \\ []) do
    with {:ok, email} <- fetch_email(params),
         {:ok, age} <- fetch_age(params),
         {:ok, role} <- fetch_role(params),
         attrs = %{email: email, age: age, role: role, nickname: params["nickname"] || email},
         {:ok, user} <- Repo.insert(User.import_changeset(%User{}, attrs)) do
      if Keyword.get(opts, :notify, false), do: send_welcome(user)
      {:ok, user}
    end
  end

  # The provider lowercases addresses before its uniqueness check, so match it here.
  defp fetch_email(%{"email" => email}) when is_binary(email), do: {:ok, String.downcase(email)}
  defp fetch_email(_params), do: {:error, :invalid_email}

  defp fetch_age(%{"age" => age}) do
    case parse_int(age) do
      {:ok, age} when age < @min_age -> {:error, :underage}
      {:ok, age} -> {:ok, min(age, @max_age)}
      :error -> {:error, :invalid_age}
    end
  end

  defp fetch_age(_params), do: {:error, :invalid_age}

  defp parse_int(value) when is_integer(value), do: {:ok, value}

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_int(_value), do: :error

  defp fetch_role(%{"role" => role}) when is_map_key(@roles, role), do: {:ok, Map.fetch!(@roles, role)}
  defp fetch_role(_params), do: {:error, :invalid_role}

  defp send_welcome(user) do
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn ->
      Mailer.deliver(welcome_email(user))
    end)
  end

  defp welcome_email(user) do
    name = user.nickname || "there"
    "Hi #{name}, welcome! Enjoy your account."
  end
end
```

Notes on assumptions: `Accounts.TaskSupervisor` must be started in the application's supervision tree, `User.import_changeset/2` must cast the four fields and call `unique_constraint(:email)`, and the role map must match the real role names. The `Mailer` alias assumes it lives under `Accounts`; adjust if not.
