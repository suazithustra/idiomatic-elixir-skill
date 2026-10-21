# Review: Accounts.UserImporter

## Findings

1. **Bug: the age cap does nothing.** `age = 120` inside `if` only rebinds `age` within that block. Ages above 120 pass through unchanged (and the compiler warns about the unused variable). Fix: `age = min(age, 120)`.

2. **Security: `String.to_atom/1` on external input.** Atoms are never garbage collected, so a stream of distinct role strings can exhaust the atom table and crash the VM. It also raises on a missing `"role"`, and that happens outside the `try`. Fix: map role strings through a fixed allowlist. The roles listed (`admin`, `member`, `guest`) are assumed; use the real ones.

3. **`try`/`rescue` used as control flow, with a catch-all.** `rescue _ ->` hides real bugs (a `Repo` or `Mailer` failure becomes `{:error, :invalid}`) and discards the reason. Fix: validate with `with` and return tagged errors (`:invalid_role`, `:invalid_email`, `:invalid_age`, `:underage`). `String.to_integer/1` becomes `Integer.parse/1`, and a missing email is handled explicitly.

4. **Email is downcased before the `is_binary` check.** A nil email raises inside `String.downcase/1`, so the `is_binary(email)` guard never works as a guard. Fix: check the type first, then downcase. The comment about the provider lowercasing is useful and is kept.

5. **`user[:name]` on a struct.** Structs do not implement `Access`, so this raises `UndefinedFunctionError` on every welcome email. The schema also has `nickname`, not `name`. Because `send_welcome` runs in `spawn`, the crash is silent. Fix: use `user.nickname`.

6. **Unsupervised `spawn` for email.** A failure gets no logging or restart and nothing tracks it. Fix: `Task.Supervisor.start_child/2`. This assumes an `Accounts.TaskSupervisor` in the supervision tree; add one if it doesn't exist.

7. **Insert errors are discarded.** `_ -> {:error, :insert_failed}` throws away the changeset, so callers can't tell a duplicate email from a bad field. Fix: return `{:error, reason}` as given. Also, `Repo.insert/1` on a bare struct skips validation and constraint handling. A `User.changeset/2` with `unique_constraint(:email)` is the usual route; this code assumes one exists.

8. **Inconsistent return type.** `return_id: true` returns a bare id and the default returns `{:ok, user}`, so callers can't pattern match one shape. Fix: always return `{:ok, user}`; callers read `user.id`. This changes the API, so check callers first.

9. **Option handling.** `opts[:notify] && !opts[:silent]` is hard to read, and `opts[:silent]` overrides `notify`. Fix: read both with `Keyword.get/3` and name the result.

10. **Style.** `Mailer` is not aliased and is unqualified (probably `Accounts.Mailer`; adjust). The pipe into an anonymous function in `welcome_email` is needless, so use string interpolation. The comments restate the code ("Get the role from params", "send the email"), so they are removed. Add `@spec` and `@doc`.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV/JSON source.
  """

  alias Accounts.{Mailer, Repo, User}

  # Assumed role list; replace with the real one.
  @roles %{"admin" => :admin, "member" => :member, "guest" => :guest}
  @min_age 18
  @max_age 120

  @type error ::
          :invalid_role
          | :invalid_email
          | :invalid_age
          | :underage
          | Ecto.Changeset.t()

  @doc """
  Imports a single user from string-keyed `params`.

  Options:

    * `:notify` - send a welcome email after insert (default `false`)
    * `:silent` - suppress the welcome email even if `:notify` is set
  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, error()}
  def import_user(params, opts \\ []) do
    with {:ok, role} <- parse_role(params["role"]),
         {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         {:ok, user} <- insert(email, age, role, params["nickname"]) do
      if notify?(opts), do: send_welcome(user)
      {:ok, user}
    end
  end

  defp parse_role(role) when is_binary(role) do
    case Map.fetch(@roles, role) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, :invalid_role}
    end
  end

  defp parse_role(_), do: {:error, :invalid_role}

  # The provider lowercases addresses before its uniqueness check, so match it here
  defp parse_email(email) when is_binary(email), do: {:ok, String.downcase(email)}
  defp parse_email(_), do: {:error, :invalid_email}

  defp parse_age(age) when is_integer(age), do: check_age(age)

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {int, ""} -> check_age(int)
      _ -> {:error, :invalid_age}
    end
  end

  defp parse_age(_), do: {:error, :invalid_age}

  defp check_age(age) when age < @min_age, do: {:error, :underage}
  defp check_age(age), do: {:ok, min(age, @max_age)}

  defp insert(email, age, role, nickname) do
    %User{email: email, age: age, role: role, nickname: nickname || email}
    |> Repo.insert()
  end

  defp notify?(opts) do
    Keyword.get(opts, :notify, false) and not Keyword.get(opts, :silent, false)
  end

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

Behavior changes to confirm: `return_id` is removed (finding 8), errors are now specific instead of `:invalid` / `:insert_failed`, and the role allowlist and `Accounts.TaskSupervisor` are assumptions. The code was not compiled or run, because `User`, `Repo` and `Mailer` are not available here.
