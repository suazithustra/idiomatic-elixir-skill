# Review: Accounts.UserImporter

## Findings

1. **Bug: age clamp never applies.** `if age > 120 do age = 120 end` rebinds `age` only inside the `if`, so the outer `age` is unchanged (the compiler warns about this). Use `min(age, 120)`.
2. **Security: `String.to_atom/1` on external input.** Atoms are never garbage collected, so untrusted roles can exhaust the atom table. Map roles through an explicit whitelist.
3. **Crash outside the `try`.** `String.to_atom(params["role"])` raises on a missing role (`nil` is not a string), and it sits before the `try`, so `import_user/2` raises instead of returning `{:error, _}`.
4. **`try/rescue` used as control flow.** `rescue _ ->` swallows every exception, including real bugs and DB connection errors, and reports them all as `:invalid`. Validate explicitly (`Integer.parse/1`, pattern matching) and use `with`.
5. **Dead / misordered validation.** `is_binary(email)` runs after `String.downcase/1`, which has already raised for non-binaries. Validate before transforming.
6. **Check-then-insert race.** `Repo.get_by` followed by `Repo.insert` is not atomic. Two concurrent imports can both pass the check. Rely on a unique index and `unique_constraint/2` on the changeset, and map the error to `{:error, :email_taken}`.
7. **Nested if/case pyramid and indistinct errors.** `:invalid` covers bad age, taken email and exceptions. Use a flat `with` and return distinct reasons.
8. **Inconsistent return type.** `opts[:return_id]` makes the success value either a bare id or `{:ok, user}`. The improved version always returns `{:ok, id}` or `{:ok, user}`. This changes the contract for `return_id` callers.
9. **Unsupervised `spawn/1`.** A failed delivery is silently lost with no supervision or logging. Use `Task.Supervisor.start_child/2`.
10. **`user[:name]` on a struct.** Structs do not implement Access, so this raises at runtime. Use `user.name` or `Map.get/2`. `Mailer` is also not aliased.
11. **Convoluted `welcome_email`.** The pipe into an anonymous function is pointless. Use plain interpolation.
12. **Style:** `&&`/`!` on options should be `and`/`not`; the comments restate the code (the one useful comment, about the provider's lowercasing, is kept); add `@spec` and a `@moduledoc`.
13. **Nickname default.** A blank-string nickname is now treated as missing too.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc "Imports users from an external CSV/JSON source."

  alias Accounts.{Mailer, Repo, User}
  alias Ecto.Changeset

  @roles %{"admin" => :admin, "member" => :member, "guest" => :guest}
  @min_age 18
  @max_age 120

  @spec import_user(map(), keyword()) :: {:ok, User.t() | term()} | {:error, atom()}
  def import_user(params, opts \\ []) do
    with {:ok, role} <- parse_role(params["role"]),
         {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         {:ok, user} <- insert(email, age, role, nickname(params["nickname"], email)) do
      maybe_notify(user, opts)
      {:ok, if(opts[:return_id], do: user.id, else: user)}
    end
  end

  defp parse_role(role) when is_binary(role) do
    case Map.fetch(@roles, role) do
      {:ok, _} = ok -> ok
      :error -> {:error, :invalid}
    end
  end

  defp parse_role(_), do: {:error, :invalid}

  # The provider lowercases addresses before its uniqueness check, so match it here
  defp parse_email(email) when is_binary(email), do: {:ok, String.downcase(email)}
  defp parse_email(_), do: {:error, :invalid}

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {n, ""} when n >= @min_age -> {:ok, min(n, @max_age)}
      _ -> {:error, :invalid}
    end
  end

  defp parse_age(_), do: {:error, :invalid}

  defp nickname(nick, email) when nick in [nil, ""], do: email
  defp nickname(nick, _email), do: nick

  defp insert(email, age, role, nickname) do
    %User{email: email, age: age, role: role, nickname: nickname}
    |> Changeset.change()
    |> Changeset.unique_constraint(:email)
    |> Repo.insert()
    |> case do
      {:ok, user} ->
        {:ok, user}

      {:error, %Changeset{errors: [email: {_, [constraint: :unique | _]}]}} ->
        {:error, :email_taken}

      {:error, _changeset} ->
        {:error, :insert_failed}
    end
  end

  defp maybe_notify(user, opts) do
    if opts[:notify] and not opts[:silent] do
      Task.Supervisor.start_child(Accounts.TaskSupervisor, fn ->
        Mailer.deliver(welcome_email(user))
      end)
    end

    :ok
  end

  defp welcome_email(user) do
    name = Map.get(user, :name) || "there"
    "Hi #{name}, welcome! Enjoy your account."
  end
end
```

Assumptions: `Accounts.TaskSupervisor` is started in the application tree, the `@roles` whitelist matches the real roles, and the DB has a unique index on `users.email`.
