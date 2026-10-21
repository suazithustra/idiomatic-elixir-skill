# Review: Accounts.UserImporter

## Findings

1. **Atom leak from user input (line 8).** `String.to_atom/1` on `params["role"]` creates a new atom for every distinct value. Atoms are never garbage collected, so an import file with many distinct roles can crash the VM. It also runs outside the `try`, so a missing role raises instead of returning an error. Fix: map role strings to atoms through a fixed list.

2. **The age cap does nothing (lines 15-17).** `age = 120` inside `if` only rebinds inside the `if` block. Elixir does not leak it out, so ages above 120 are inserted unchanged. The compiler warns about this. Fix: `age = min(age, 120)`.

3. **`try/rescue` hides real errors (lines 10, 38-40).** It turns every exception into `{:error, :invalid}`, including database failures and typos in this code. Bad input is already handled by the checks, so the rescue is not needed. Fix: validate with `with` and `Integer.parse/1`, and let unexpected errors crash.

4. **Checks run after the values are used (lines 12-21).** `String.downcase(nil)` raises when the email is missing, and `is_binary(email)` is only checked after the downcase, so it can never fail. `String.to_integer/1` also raises on bad input. Fix: check types first, with pattern matching.

5. **Inconsistent return type (line 30).** The function returns either `user.id` or `{:ok, user}` depending on an option. Callers cannot pattern match on one shape. Fix: always return `{:ok, user}` and let callers read `.id`. This changes behaviour for callers that pass `return_id: true`.

6. **`user[:name]` raises (line 49).** Structs do not implement the Access behaviour (the `[]` syntax), so this raises `UndefinedFunctionError`. The welcome email crashes every time, and because it runs in an unlinked process, nothing reports it. Fix: use a field that exists. I assumed `nickname`, since the code never sets a name.

7. **Unsupervised `spawn` (line 45).** A failed delivery is lost with no log or retry, and the process is not tied to the supervision tree. Fix: `Task.Supervisor.start_child/2`. This assumes a `Task.Supervisor` named `Accounts.TaskSupervisor` is started in the application.

8. **Insert error details are dropped (lines 32-33).** `_ -> {:error, :insert_failed}` throws away the changeset, so callers cannot tell a duplicate email from other errors. Inserting a bare struct also skips validations and unique-constraint handling. Fix: build a changeset (`User.changeset/2`, assumed to exist) and return `{:error, changeset}`.

9. **Minor.**
   - `opts[:notify] && !opts[:silent]` is a double flag. Use `Keyword.get/3` and one clear condition.
   - `Mailer` is not aliased.
   - The pipe into an anonymous function in `welcome_email` is needless.
   - Comments such as "Get the role from params" repeat the code.
   - There is no `@doc` or `@spec`.

## Improved code

Assumptions: the allowed roles are `admin`, `member` and `guest`. `Accounts.TaskSupervisor` and `User.changeset/2` exist. Adjust these to the real app.

```elixir
defmodule Accounts.UserImporter do
  @moduledoc "Imports users from an external CSV/JSON source."

  alias Accounts.{Mailer, Repo, User}

  @roles %{"admin" => :admin, "member" => :member, "guest" => :guest}
  @min_age 18
  @max_age 120

  @doc """
  Imports one user from string-keyed `params`.

  Options:
    * `:notify` - send a welcome email after insert (default `false`)
  """
  @spec import_user(map(), keyword()) ::
          {:ok, User.t()} | {:error, :invalid} | {:error, Ecto.Changeset.t()}
  def import_user(params, opts \\ []) do
    with {:ok, role} <- parse_role(params["role"]),
         {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         attrs = %{email: email, age: age, role: role, nickname: params["nickname"] || email},
         {:ok, user} <- attrs |> User.changeset() |> Repo.insert() do
      if Keyword.get(opts, :notify, false), do: send_welcome(user)
      {:ok, user}
    end
  end

  # The provider lowercases addresses before its uniqueness check, so match it here.
  defp parse_email(email) when is_binary(email), do: {:ok, String.downcase(email)}
  defp parse_email(_), do: {:error, :invalid}

  defp parse_role(role) when is_binary(role), do: Map.fetch(@roles, role) |> or_invalid()
  defp parse_role(_), do: {:error, :invalid}

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {age, ""} when age >= @min_age -> {:ok, min(age, @max_age)}
      _ -> {:error, :invalid}
    end
  end

  defp parse_age(_), do: {:error, :invalid}

  defp or_invalid({:ok, _} = ok), do: ok
  defp or_invalid(:error), do: {:error, :invalid}

  defp send_welcome(user) do
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn ->
      Mailer.deliver(welcome_email(user))
    end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname || "there"}, welcome! Enjoy your account."
  end
end
```
