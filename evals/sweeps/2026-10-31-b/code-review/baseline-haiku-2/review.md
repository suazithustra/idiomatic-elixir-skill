# Review: `Accounts.UserImporter`

## Findings

1. **Atoms are created from untrusted input.** `String.to_atom(params["role"])` turns any string from the import file into an atom. Atoms are never garbage collected, so a large or hostile file can exhaust the VM's atom table and crash the node. The same line also runs outside the `try`, so a missing `role` key raises and the `rescue` never sees it. Fix: map known role strings to atoms with a lookup and return an error for anything else. The role list below is a placeholder; replace it with the roles your `User` schema actually uses.

2. **The age cap never applies.** Inside `if age > 120 do age = 120 end`, the rebinding of `age` stays inside the `if` block. In Elixir, variables set inside `if` do not leak out. So an age of 150 is stored as 150. Fix: `min(age, 120)`.

3. **A blanket `rescue` hides real failures.** `rescue _ -> {:error, :invalid}` turns every exception into "invalid input", including database outages, bad config, and bugs in this module. The caller cannot tell a bad row from a broken system. Fix: validate inputs with explicit return values and let unexpected exceptions raise.

4. **`String.to_integer/1` fails on integer input.** JSON (JavaScript Object Notation) files often hold `"age": 25` as a number. `String.to_integer(25)` raises, and the rescue then reports the row as invalid. Fix: accept both integers and strings, using `Integer.parse/1` for strings.

5. **Return values are inconsistent.** With `return_id: true`, the function returns a bare integer. Otherwise it returns `{:ok, user}`. Callers have to know which shape to expect, and a success is not always an `{:ok, _}` tuple. Fix: always return `{:ok, value}`. This changes the bare-id case, so callers that pattern-match on an integer must be updated.

6. **Uniqueness check is racy.** `Repo.get_by` followed by `Repo.insert` is a check-then-act pattern (TOCTOU, time-of-check to time-of-use). Two imports of the same email at the same time can both pass the check. The database unique index is the real guard. The fix is to make sure the table has a unique index on `email` and to treat the insert error for that constraint as `:invalid`. The pre-check can stay as a cheap early exit, but it is not a guarantee.

7. **Welcome email fails silently and reads a missing field.** `spawn/1` starts an unsupervised process. If `Mailer.deliver` crashes, nothing logs it and nothing retries it. Fix: run it under a `Task.Supervisor`. Separately, `user[:name]` uses the `Access` behaviour (the `[]` lookup). Ecto schema structs do not implement `Access`, so this raises `UndefinedFunctionError`. The `name` field is also never set on insert. Fix: read the field with `Map.get/2`.

8. **Email is checked after it is used.** `String.downcase(params["email"])` runs before the `is_binary(email)` check. A `nil` email raises, and the broad rescue hides it. Fix: check the type first, then downcase.

9. **Dead and noisy code.** The `if ... do x end` rebinding bug (finding 2) is one case. The comments "Get the role from params" and "send the email" repeat the code. The greeting is built with a needless anonymous function. The nested `if` and `case` blocks are easier to read as a `with` chain. Fix: the rewrite below.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV (comma-separated values) or JSON source.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  # Must match the roles defined in the User schema.
  @roles %{"admin" => :admin, "member" => :member, "guest" => :guest}

  @doc """
  Imports one user from `params`.

  Returns `{:ok, user}`, or `{:ok, id}` when `return_id: true` is passed.
  Returns `{:error, :invalid}` for bad input or a duplicate email, and
  `{:error, :insert_failed}` when the database rejects the row.

  Options:
    * `:notify` - send a welcome email (default `false`)
    * `:silent` - suppress the welcome email even when `:notify` is set
    * `:return_id` - return the id instead of the user
  """
  def import_user(params, opts \\ []) do
    with {:ok, email} <- fetch_email(params),
         {:ok, age} <- parse_age(params["age"]),
         {:ok, role} <- parse_role(params["role"]),
         :ok <- ensure_unique(email),
         {:ok, user} <-
           insert_user(
             email: email,
             age: age,
             role: role,
             nickname: params["nickname"] || email
           ) do
      maybe_notify(user, opts)
      {:ok, if(opts[:return_id], do: user.id, else: user)}
    end
  end

  defp fetch_email(%{"email" => email}) when is_binary(email),
    do: {:ok, String.downcase(email)}

  defp fetch_email(_), do: {:error, :invalid}

  defp parse_age(age) when is_integer(age), do: validate_age(age)

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {value, ""} -> validate_age(value)
      _ -> {:error, :invalid}
    end
  end

  defp parse_age(_), do: {:error, :invalid}

  defp validate_age(age) when age >= @min_age, do: {:ok, min(age, @max_age)}
  defp validate_age(_), do: {:error, :invalid}

  defp parse_role(role) do
    case Map.fetch(@roles, role) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, :invalid}
    end
  end

  # The unique index on users.email is the real guard against duplicates.
  # This check only avoids the insert attempt in the common case.
  defp ensure_unique(email) do
    if Repo.get_by(User, email: email), do: {:error, :invalid}, else: :ok
  end

  defp insert_user(attrs) do
    case Repo.insert(struct(User, attrs)) do
      {:ok, user} -> {:ok, user}
      {:error, _changeset} -> {:error, :insert_failed}
    end
  end

  defp maybe_notify(user, opts) do
    if opts[:notify] && !opts[:silent], do: send_welcome(user)
  end

  # Requires an `Accounts.TaskSupervisor` in the application's supervision tree.
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

## Notes on the rewrite

- `Repo.insert/1` errors are collapsed to `:insert_failed`, as in the original. Log the changeset at the call site if you need the detail.
- The `rescue` is gone. Unexpected exceptions now reach the caller. If the importer runs in a batch, wrap each row in the caller, not here.
- The `Accounts.TaskSupervisor` name is an assumption. Add the supervisor to the application tree, or substitute the name you already use.
- The rewrite has not been compiled or run. The role map and supervisor name need to match your project.
