# Review: `Accounts.UserImporter`

## Findings

1. **Bug: the age cap never applies.** `if age > 120 do age = 120 end` rebinds `age` only inside the `if`. Elixir has no leaking scope, and the compiler warns about it. Ages above 120 pass through unchanged. Fix: `age = min(age, 120)`.
2. **Security / resource leak: `String.to_atom/1` on external input.** Atoms are never garbage-collected, so an attacker-controlled `"role"` can exhaust the atom table and crash the VM. It also raises on `nil`, and that raise sits outside the `try`. Fix: map the role through an explicit whitelist.
3. **`try/rescue` used as control flow.** `rescue _ ->` swallows every exception, including real bugs and DB connection errors, and reports them as `:invalid`. It also hides the `nil` crash on `params["email"]`. Fix: validate explicitly with `with` and return tagged errors. Let genuine failures crash.
4. **Check-then-insert race.** `Repo.get_by` followed by `Repo.insert` is not atomic, so two concurrent imports can both pass the check. Fix: insert through a changeset with `unique_constraint(:email)` (backed by a unique index) and handle `{:error, changeset}`. This assumes that index exists.
5. **Inconsistent return shapes.** `opts[:return_id]` returns a bare integer in place of `{:ok, user}`. Callers cannot pattern-match uniformly. I removed it, because callers can use `user.id`.
6. **Error reasons are collapsed.** Duplicate email, bad age, underage, and a missing field all return `:invalid`. The insert failure discards the changeset. Fix: return distinct reasons.
7. **Bug: `user[:name]` on a struct.** Structs don't implement `Access`, so this raises at runtime. It would raise inside the unsupervised spawned process, where nobody sees the failure. `%User{}` also has no `:name` field in this code. Fix: use `user.nickname`.
8. **Unsupervised `spawn`.** A crash is silent, there is no backpressure, and nothing is linked. Fix: use `Task.Supervisor.start_child/2`. This assumes `Accounts.TaskSupervisor` is in the supervision tree.
9. **Redundant or dead code.**
   - `is_binary(email)` runs after `String.downcase`, which already raises on non-binaries.
   - `opts[:notify] && !opts[:silent]` is convoluted. Use `Keyword.get(opts, :notify, false)`, since `silent` only negates it.
   - `welcome_email` builds a string through an anonymous function applied inline.
   - `Mailer` is not aliased.
10. **Style.**
    - The comments restate the code and should go.
    - `&&` and `!` are used on booleans where `and` and `not` fit.
    - There are no `@moduledoc`, `@doc`, or `@spec`.
    - The function does too much, so I split it into small private steps.
    - `nickname` falls back to the email only when it is `nil`. An empty string is kept. I preserved that behaviour.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV/JSON source.
  """

  alias Accounts.{Mailer, Repo, User}

  @roles %{"admin" => :admin, "member" => :member}
  @min_age 18
  @max_age 120

  @type error ::
          :invalid_email | :invalid_age | :invalid_role | :underage | {:insert_failed, Ecto.Changeset.t()}

  @doc """
  Imports a single user from string-keyed `params`.

  Options:

    * `:notify` - send a welcome email after insert (default `false`)
  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, error()}
  def import_user(params, opts \\ []) do
    with {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         {:ok, role} <- parse_role(params["role"]),
         {:ok, user} <- insert(email, age, role, params["nickname"]) do
      if Keyword.get(opts, :notify, false), do: send_welcome(user)
      {:ok, user}
    end
  end

  # The provider lowercases addresses before its uniqueness check, so match it here.
  defp parse_email(email) when is_binary(email), do: {:ok, String.downcase(email)}
  defp parse_email(_), do: {:error, :invalid_email}

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {age, ""} when age >= @min_age -> {:ok, min(age, @max_age)}
      {_age, ""} -> {:error, :underage}
      _ -> {:error, :invalid_age}
    end
  end

  defp parse_age(age) when is_integer(age) and age >= @min_age, do: {:ok, min(age, @max_age)}
  defp parse_age(age) when is_integer(age), do: {:error, :underage}
  defp parse_age(_), do: {:error, :invalid_age}

  defp parse_role(role) do
    case Map.fetch(@roles, role) do
      {:ok, _} = ok -> ok
      :error -> {:error, :invalid_role}
    end
  end

  defp insert(email, age, role, nickname) do
    %User{email: email, age: age, role: role, nickname: nickname || email}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:email)
    |> Repo.insert()
    |> case do
      {:ok, user} -> {:ok, user}
      {:error, changeset} -> {:error, {:insert_failed, changeset}}
    end
  end

  defp send_welcome(user) do
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn ->
      user |> welcome_email() |> Mailer.deliver()
    end)
  end

  defp welcome_email(user), do: "Hi #{user.nickname}, welcome! Enjoy your account."
end
```

## Assumptions and behaviour changes

- Roles are limited to `admin` and `member`. Adjust `@roles` to the real set.
- The `:return_id` and `:silent` options are removed.
- Errors are now specific tagged tuples.
- Unexpected exceptions now propagate in place of being reported as `:invalid`.
- `welcome_email` uses `nickname`, because `User` is a struct without a `:name` field in this code.
