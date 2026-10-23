# Review: `Accounts.UserImporter`

## Findings

1. **Atom leak from untrusted input** (`String.to_atom(params["role"])`, line 8). Every distinct role string in an import file creates a new atom, and atoms are never garbage collected. Worse, any string is accepted as a role. Map the role through a fixed lookup instead.

2. **Age clamp is a no-op** (lines 15–17). `age = 120` inside `if` does not rebind the outer `age`, since variables bound in an `if` do not leak out in Elixir. Ages above 120 are stored unclamped. `min(age, 120)` does what was intended.

3. **Blanket `rescue _ -> {:error, :invalid}`** (lines 42–44). This hides real bugs and also swallows database and connection errors, reporting them as bad input. Validate the inputs explicitly so there is nothing to rescue.

4. **`is_binary(email)` check comes after `String.downcase/1`** (lines 12, 21). If `params["email"]` is `nil`, `String.downcase/1` raises, and the `rescue` turns that into `:invalid` by accident. The `is_binary` guard is dead code in practice. Validate first.

5. **`user[:name]` on a struct** (line 53). `%User{}` does not implement the Access behaviour, so `user[:name]` raises `UndefinedFunctionError`. `welcome_email/1` runs inside an unsupervised `spawn`, so the failure is silent and no welcome emails are sent. Use `Map.get/2` or `user.name`. Confirm whether `User` has a `:name` field at all.

6. **Unsupervised `spawn` for email delivery** (line 49). A crash is not logged or supervised, and the process is not tracked. Use a `Task.Supervisor` (this assumes `Accounts.TaskSupervisor` is in the supervision tree; adjust to the app's actual supervisor).

7. **Check-then-insert race** (lines 24–25). `get_by` followed by `insert` can admit duplicates under concurrent imports. The unique index on `email` is the real guard, so the insert error path should handle a unique-constraint failure rather than rely on the pre-check. Not fixed here because it depends on the schema's constraints.

8. **Deep nesting of `if`/`case`/`else`** (whole function). Five levels of nesting obscure a linear sequence of validation steps. A `with` chain reads top to bottom.

9. **Inconsistent return shape** (line 31). With `return_id: true` the function returns a bare integer, otherwise `{:ok, user}`. Callers must special-case the option. Left as-is for compatibility, but flagged as a candidate for a separate change.

10. **Convoluted `welcome_email/1`** (line 55). The pipe into an anonymous function adds nothing; interpolation is clearer.

11. **Comments restate the code** (lines 2, 5, 7, 11, 48). The module comment should be `@moduledoc` and the function comment should be `@doc`. Keep the line 11 comment, since it records a non-obvious reason. Drop the others.

12. **Behaviour changes in the rewrite** (for review, not bugs):
    - Unknown roles are now rejected. Previously any string became a role.
    - Exceptions from `Repo` calls now propagate instead of becoming `{:error, :invalid}`. Callers that depended on that must handle exceptions.
    - Ages above 120 are now stored as 120, as originally intended.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV/JSON source.
  """

  alias Accounts.{Repo, User}

  # Replace with the schema's real roles.
  @roles %{"admin" => :admin, "member" => :member}

  @doc """
  Imports a single user from the given params.

  Options:
    * `:notify` - send a welcome email (requires `:silent` to be unset)
    * `:silent` - suppress the welcome email
    * `:return_id` - return the new user's id instead of `{:ok, user}`
  """
  def import_user(params, opts \\ []) do
    # The provider lowercases addresses before its uniqueness check, so match it here
    with {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         {:ok, role} <- parse_role(params["role"]),
         :ok <- ensure_unique(email) do
      %User{email: email, age: age, role: role, nickname: params["nickname"] || email}
      |> insert_user(opts)
    end
  end

  defp parse_email(email) when is_binary(email), do: {:ok, String.downcase(email)}
  defp parse_email(_), do: {:error, :invalid}

  defp parse_age(value) when is_binary(value) do
    case Integer.parse(value) do
      {age, ""} when age >= 18 -> {:ok, min(age, 120)}
      _ -> {:error, :invalid}
    end
  end

  defp parse_age(_), do: {:error, :invalid}

  defp parse_role(role) do
    case Map.fetch(@roles, role) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, :invalid}
    end
  end

  defp ensure_unique(email) do
    if Repo.get_by(User, email: email), do: {:error, :invalid}, else: :ok
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
    name = Map.get(user, :name) || "there"
    "Hi #{name}, welcome! Enjoy your account."
  end
end
```

## Notes

- The rewrite has not been compiled or run. The schema, `Accounts.TaskSupervisor`, and `Mailer` are assumed from context.
- Finding 7 (the race) is not addressed in code. Handling the unique-constraint error needs the schema's `unique_constraint/2` declaration.
