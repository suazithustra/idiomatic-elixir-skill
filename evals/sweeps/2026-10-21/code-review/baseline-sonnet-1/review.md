# Review: Accounts.UserImporter

## Findings

1. **`String.to_atom/1` on external input.** Atoms are never garbage collected, so a feed with many distinct roles can exhaust the VM's atom table and crash the node. It is also outside the `try`, so a missing `"role"` raises `ArgumentError` instead of returning an error. Fix: match against an allowlist of roles.

2. **`if age > 120 do age = 120 end` does nothing.** Variables bound inside `if` do not leak out, so age is never capped (the compiler warns about it). Fix: `min(age, 120)`.

3. **`try/rescue` with `_ ->` hides every failure.** A nil email, a bad integer, a bug in `send_welcome`, or a database error all become `{:error, :invalid}`. Fix: parse explicitly with `Integer.parse/1` and a `with` chain, and let real bugs crash.

4. **`is_binary(email)` is checked after `String.downcase/1`.** By then a non-string has already raised, so the check is dead. Validate before transforming.

5. **Insert errors are discarded.** `_ -> {:error, :insert_failed}` throws away the changeset errors (for example a duplicate email). `Repo.insert` is also given a bare struct, so no validations or unique constraints run. Fix: build a changeset (`User.import_changeset/2`, assumed to exist or to be added) and return `{:error, changeset}`.

6. **Inconsistent return type.** With `return_id: true` the function returns a bare id; otherwise `{:ok, user}`. Callers cannot pattern-match one shape. Fix: remove the option, or return `{:ok, id}`. The improved version removes it; callers can use `user.id`.

7. **`spawn/1` for the email is unsupervised.** Failures vanish and nothing is retried or awaited at shutdown. Fix: `Task.Supervisor.start_child/2` under a supervisor named `Accounts.TaskSupervisor` (assumed; add it to the application tree).

8. **`user[:name]` raises on a struct.** Structs do not implement Access (the `[]` lookup protocol). It would crash inside the spawned process and no one would see it. `User` also has no `:name` field in this module; `nickname` is used instead.

9. **`welcome_email/1` is needlessly convoluted.** The anonymous function piped into a call is unreadable, and one string interpolation is enough.

10. **Smaller points.** `opts[:notify] && !opts[:silent]` is clearer as `notify and not silent` using `Keyword.get/3`. `Mailer` is not aliased. There are no `@moduledoc`, `@doc`, or `@spec`. Comments restate the code (`# Get the role from params`); keep only the one that explains why (the downcase).

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

  @type error :: :invalid | Ecto.Changeset.t()

  @doc """
  Imports a single user from string-keyed `params`.

  Options:

    * `:notify` - send a welcome email after insert (default `false`)
  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, error()}
  def import_user(params, opts \\ []) do
    with {:ok, role} <- parse_role(params["role"]),
         {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         {:ok, user} <- insert(email, age, role, params["nickname"]) do
      if Keyword.get(opts, :notify, false), do: send_welcome(user)
      {:ok, user}
    end
  end

  defp parse_role(role) when is_binary(role) do
    case Map.fetch(@roles, role) do
      {:ok, _} = ok -> ok
      :error -> {:error, :invalid}
    end
  end

  defp parse_role(_), do: {:error, :invalid}

  # The provider lowercases addresses before its uniqueness check, so match it here.
  defp parse_email(email) when is_binary(email), do: {:ok, String.downcase(email)}
  defp parse_email(_), do: {:error, :invalid}

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {n, ""} when n >= @min_age -> {:ok, min(n, @max_age)}
      _ -> {:error, :invalid}
    end
  end

  defp parse_age(_), do: {:error, :invalid}

  defp insert(email, age, role, nickname) do
    attrs = %{email: email, age: age, role: role, nickname: nickname || email}

    attrs
    |> User.import_changeset()
    |> Repo.insert()
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

Assumptions I could not check from the file alone: the role names in `@roles`, `User.import_changeset/1`, the `Accounts.TaskSupervisor` process, and that `Mailer` lives under `Accounts`. Adjust these to match the project. The code has not been compiled.
