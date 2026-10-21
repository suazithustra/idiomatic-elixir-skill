# Review: `Accounts.UserImporter`

## Findings

1. **Welcome emails never send.** `welcome_email/1` reads `user[:name]`, but `User` is a struct and structs do not support `[]` access. The call raises inside a process started with `spawn`, so the crash is silent. The fix is to read a real field (`user.nickname`) and send the mail from a supervised task. Confirmed by running the original against stub modules: no mail arrives.

2. **Untrusted input creates atoms.** `String.to_atom(params["role"])` makes a permanent atom (a name the Erlang VM never frees) for every distinct role string in the import file. A crafted file can fill the atom table and crash the VM. A missing role also raises before the `try` block starts. The fix is to map known role strings to atoms and reject everything else.

3. **The age cap has no effect.** In Elixir, `age = 120` inside an `if` does not change the `age` variable outside it. Ages above 120 are stored unchanged. Confirmed: `"130"` is saved as `130`. The fix is `min(age, 120)`.

4. **Integer ages are rejected.** JSON (JavaScript Object Notation) files give numbers, not strings. `String.to_integer/1` raises on a number, and the blanket `rescue` turns that into `{:error, :invalid}`. Confirmed: an integer age of `30` returns an error. The fix is to accept both integers and numeric strings.

5. **The blanket `rescue` hides real failures.** `rescue _ ->` turns every exception into `{:error, :invalid}`, including a lost database connection or a bug in this module. The `is_binary(email)` check is also dead code: a non-string email already raised inside `String.downcase/1`. The fix is to validate each field with explicit clauses and a `with` expression, and to let unexpected errors raise.

6. **The return type depends on an option.** With `return_id: true` the function returns a bare id; otherwise it returns a tuple. Callers have to know which form they asked for. The fix is to always return `{:ok, user}` and let callers read `.id`. The rewrite keeps the option so existing callers do not break.

7. **The welcome email runs in an unsupervised process.** `spawn/1` is not linked to any supervisor, so a failed send is logged and then lost, with no tracking. The fix is `Task.Supervisor.start_child/2`.

8. **Style.** `greeting |> (fn text -> ... end).()` is an anonymous function called on the spot; string interpolation does the same job. Comments such as "Get the role from params" repeat the code. The module has no `@moduledoc` or `@doc`.

## Choices made in the rewrite

- **Roles.** `@roles` holds placeholder values (`admin`, `member`). Replace them with the real role list. Unknown roles are now rejected; the original accepted any string.
- **Greeting.** The greeting uses `nickname`, which falls back to the email address. The original read a `:name` field that the struct does not have. Confirm which field the greeting should use.
- **Supervisor.** `Accounts.TaskSupervisor` must be started in the application's supervision tree.
- **Errors.** Database errors now raise instead of returning `{:error, :invalid}`.
- **Email format.** No format check was added; the original did none either.

## Rewritten module

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  # Roles accepted from the import file. Replace with the real role list.
  @roles %{"admin" => :admin, "member" => :member}

  @doc """
  Inserts a user built from `params`.

  Returns `{:ok, user}` on success, `{:error, :invalid}` when a field fails
  validation, or `{:error, :insert_failed}` when the insert is rejected.

  Options:

    * `:notify` - send a welcome email (default: `false`)
    * `:silent` - suppress the welcome email even when `:notify` is set
    * `:return_id` - return the new user's id instead of `{:ok, user}`
  """
  def import_user(params, opts \\ []) do
    with {:ok, email} <- parse_email(params["email"]),
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

  defp parse_email(email) when is_binary(email), do: {:ok, String.downcase(email)}
  defp parse_email(_), do: {:error, :invalid}

  # Accepts integers (JSON) and numeric strings (CSV). Ages above the maximum
  # are reduced to it; ages below the minimum are rejected.
  defp parse_age(age) when is_integer(age), do: check_age(age)

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {value, ""} -> check_age(value)
      _ -> {:error, :invalid}
    end
  end

  defp parse_age(_), do: {:error, :invalid}

  defp check_age(age) when age >= @min_age, do: {:ok, min(age, @max_age)}
  defp check_age(_), do: {:error, :invalid}

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
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

## Verification

The rewrite compiles on Elixir 1.20.3. It passed 12 checks run against stub modules for `Repo`, `Mailer`, `User`, and the task supervisor: email case, age cap for strings and integers, age floor, non-numeric age, unknown role, missing role, missing email, `return_id`, insert failure, and the welcome mail. The stubs stand in for the real application, so the checks do not cover the real database or mailer.
