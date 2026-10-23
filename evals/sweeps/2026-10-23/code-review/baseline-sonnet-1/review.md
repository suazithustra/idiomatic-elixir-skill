# Review: Accounts.UserImporter

## Findings

1. **Atom exhaustion (memory leak) from user input.** `String.to_atom(params["role"])` creates a new atom for every distinct role string, and atoms are never garbage collected. Imported data can crash the VM this way. It also raises on a missing role, and that call sits outside the `try`. Fix: map roles from a fixed list of allowed strings.

2. **The age cap does nothing.** `if age > 120 do age = 120 end` rebinds `age` only inside the `if`. After the block, `age` is unchanged, so an age of 500 is stored as 500. Fix: `min(age, 120)`.

3. **`try/rescue` hides every error.** Bad input, a database failure and plain bugs all become `{:error, :invalid}`. `String.to_integer("abc")` and `String.downcase(nil)` are expected failures, but they should be handled with explicit checks. Fix: parse with `Integer.parse/1` and validate with pattern matching in a `with`.

4. **`is_binary(email)` runs too late.** It comes after `String.downcase`, which already raised for a non-string. The check never does anything.

5. **Check-then-insert race.** `Repo.get_by` followed by `Repo.insert` lets two concurrent imports of the same email both pass the check. Fix: insert through a changeset with `unique_constraint(:email)` and a database unique index, and drop the lookup. This also removes one query.

6. **Inserting a bare struct skips validation.** Use a changeset. This also lets you return the real error instead of `{:error, :insert_failed}`, which discards the reason.

7. **A duplicate email returns `:invalid`.** The caller cannot tell a duplicate from bad data. Return `{:error, :email_taken}` (or the changeset).

8. **The return type depends on an option.** With `return_id: true` the function returns a bare id, otherwise `{:ok, user}`. Callers have to know the option to pattern match. Return `{:ok, user}` always. The caller can read `user.id`.

9. **Welcome email problems.**
   - `spawn` is unsupervised, so failures are silent and the work is lost on shutdown. Use `Task.Supervisor.start_child/2`.
   - `user[:name]` uses the Access protocol, which structs do not implement, so it raises. If `User` has no `:name` field, it is the wrong field anyway. This version uses `nickname`.
   - `Mailer` is not aliased.
   - `opts[:notify] && !opts[:silent]` is hard to read. Use `Keyword.get/3` and a plain boolean.
   - The anonymous function piped into a call is pointless. Use string interpolation.

10. **Style.** The comments restate the code. Use `@moduledoc` and `@doc`. Split the function into small steps, so there is no deeply nested `if/case/if`.

## Assumptions

- `Accounts.Mailer` and `Accounts.TaskSupervisor` exist or will be added. `User` has `email`, `age`, `role`, `nickname`.
- Allowed roles are `admin`, `member` and `guest`. Change `@roles` to match the real set.
- An age over 120 is capped, as the original intended. Rejecting it may be better, depending on the data source.
- The database has a unique index on `users.email`. Emails are stored lowercase, so the constraint matches the provider's check.
- I have not compiled or run this.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV/JSON source.
  """

  import Ecto.Changeset

  alias Accounts.{Mailer, Repo, User}

  @roles %{"admin" => :admin, "member" => :member, "guest" => :guest}
  @min_age 18
  @max_age 120

  @doc """
  Imports one user from string-keyed `params`.

  Options:

    * `:notify` - send a welcome email after a successful insert (default `false`)
    * `:silent` - suppress the email even when `:notify` is set (default `false`)

  Returns `{:ok, user}`, `{:error, :invalid}`, `{:error, :email_taken}`,
  or `{:error, changeset}`.
  """
  @spec import_user(map(), keyword()) ::
          {:ok, User.t()} | {:error, :invalid | :email_taken | Ecto.Changeset.t()}
  def import_user(params, opts \\ []) do
    with {:ok, role} <- parse_role(params["role"]),
         {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         {:ok, user} <- insert(email, age, role, params["nickname"] || email) do
      if Keyword.get(opts, :notify, false) and not Keyword.get(opts, :silent, false) do
        send_welcome(user)
      end

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
      {age, ""} when age >= @min_age -> {:ok, min(age, @max_age)}
      _ -> {:error, :invalid}
    end
  end

  defp parse_age(_), do: {:error, :invalid}

  defp insert(email, age, role, nickname) do
    %User{}
    |> change(email: email, age: age, role: role, nickname: nickname)
    |> unique_constraint(:email)
    |> Repo.insert()
    |> case do
      {:ok, user} -> {:ok, user}
      {:error, %Ecto.Changeset{errors: [email: {_, [constraint: :unique | _]}]}} -> {:error, :email_taken}
      {:error, changeset} -> {:error, changeset}
    end
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
