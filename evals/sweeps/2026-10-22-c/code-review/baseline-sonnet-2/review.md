# Review: Accounts.UserImporter

## Findings

1. **Bug: `age = 120` inside `if` has no effect.** Rebinding in an `if` block doesn't leak out, so the age cap is never applied (and the compiler warns about an unused variable). Use `min(age, 120)`.
2. **Security: `String.to_atom/1` on external input.** Atoms are never garbage collected, so untrusted roles can exhaust the atom table. A nil role also raises, outside the `try`. Map known role strings to atoms explicitly.
3. **`try/rescue` as control flow swallows everything.** `_ -> {:error, :invalid}` hides real bugs (e.g. the `user[:name]` crash, DB errors) and turns them into "invalid". Replace it with `with` and explicit parsing (`Integer.parse/1`), so only expected failures become error tuples.
4. **Bug: `is_binary(email)` is checked after `String.downcase/1`.** A non-binary email has already raised by then, so the check is dead code. Validate before transforming.
5. **Race condition: check-then-insert.** `Repo.get_by` followed by `Repo.insert` can insert a duplicate under concurrency. Rely on a unique index and `unique_constraint/2`, and return `{:error, :email_taken}`.
6. **Bug: `user[:name]` on a struct.** Structs don't implement `Access`, so this raises at runtime. It sits inside an unsupervised process, so the failure is silent. Use field access (`user.nickname` here, since `name` may not exist on the schema).
7. **Unsupervised `spawn/1`.** Use `Task.Supervisor.start_child/2` so failures are logged and tasks are supervised (assumes an `Accounts.TaskSupervisor`). `Mailer` is also never aliased.
8. **Inconsistent return type.** `return_id: true` returns a bare id while the default returns `{:ok, user}`. Callers can't pattern match reliably. I removed the option; callers can use `user.id`.
9. **Conflated error reasons.** Duplicate email, underage and parse failures are all `:invalid`. Distinct atoms are more useful.
10. **Style.** `opts[:notify] && !opts[:silent]` is redundant, `|> (fn ...).()` is pointless, and the comments restate the code. Deep nesting is flattened with `with`.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from external CSV/JSON params.
  """

  alias Accounts.{Repo, User}
  alias Ecto.Changeset

  @roles %{"admin" => :admin, "member" => :member, "guest" => :guest}
  @min_age 18
  @max_age 120

  @type error ::
          :invalid_email | :invalid_age | :invalid_role | :underage | :email_taken | :insert_failed

  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, error()}
  def import_user(params, opts \\ []) do
    with {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         {:ok, role} <- parse_role(params["role"]),
         {:ok, user} <- insert(email, age, role, params["nickname"]) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  # The provider lowercases addresses before its uniqueness check, so match it here.
  defp parse_email(email) when is_binary(email), do: {:ok, String.downcase(email)}
  defp parse_email(_), do: {:error, :invalid_email}

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {n, ""} when n >= @min_age -> {:ok, min(n, @max_age)}
      {_, ""} -> {:error, :underage}
      _ -> {:error, :invalid_age}
    end
  end

  defp parse_age(_), do: {:error, :invalid_age}

  defp parse_role(role) do
    case Map.fetch(@roles, role) do
      {:ok, _} = ok -> ok
      :error -> {:error, :invalid_role}
    end
  end

  defp insert(email, age, role, nickname) do
    %User{email: email, age: age, role: role, nickname: nickname || email}
    |> Changeset.change()
    |> Changeset.unique_constraint(:email)
    |> Repo.insert()
    |> case do
      {:ok, user} ->
        {:ok, user}

      {:error, %Changeset{errors: [email: {_, [constraint: :unique, constraint_name: _]}]}} ->
        {:error, :email_taken}

      {:error, _changeset} ->
        {:error, :insert_failed}
    end
  end

  defp send_welcome(user) do
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn ->
      Mailer.deliver(welcome_email(user))
    end)
  end

  defp welcome_email(user) do
    "Hi " <> (user.nickname || "there") <> ", welcome! Enjoy your account."
  end
end
```

Notes: `Mailer` should be aliased to its real module. If `User` has a `name` field, use it in `welcome_email/1`. The unique-constraint error pattern depends on the constraint name matching Ecto's default; adjust if the index is custom-named.
