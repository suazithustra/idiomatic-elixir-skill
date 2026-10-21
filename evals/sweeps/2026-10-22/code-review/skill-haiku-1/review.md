# Review: `Accounts.UserImporter`

## Findings

### 1. The age cap never runs
Rule: Assign the result of `if`. Line 15 `if age > 120 do age = 120 end` rebinds `age` inside the `if` block, so the outer `age` keeps its original value and users over 120 are saved as given. Use `age = min(age, 120)`, or put the cap in `User.changeset/2`.

### 2. The welcome email never sends
Rule: Read required keys with `map.key`; structs do not implement `Access`. Line 49 `user[:name]` raises `UndefinedFunctionError` because `%User{}` is a struct. The raise happens inside the spawned process, so nothing reports it. Use the `nickname` field the module already sets (line 22), since it always holds a value.

### 3. `String.to_atom/1` on input
Rule: Convert external strings to atoms with explicit clauses. Line 8 `String.to_atom(params["role"])` lets any caller add atoms to the VM's atom table, and a missing `"role"` key crashes. Declare the field as `field :role, Ecto.Enum, values: [...]` and let the changeset cast the string.

### 4. `try/rescue` hides every bug
Rule: Return `{:ok, value}` or `{:error, reason}` for expected failures; rescue specific exceptions only. Lines 38-40 `rescue _ -> {:error, :invalid}` turn any exception, including a typo in this module, into the same error. The raising calls inside it are `String.to_integer/1` (line 13) and `String.downcase/1` on a non-string (line 12). Validate in a changeset instead, which does not raise on bad input.

### 5. Raw struct insert with a catch-all error clause
Rule: Validate input with changesets; match every expected shape. Line 22 builds `%User{}` by hand and line 24 `Repo.insert(user)` inserts it without validation. Line 32 `_ -> {:error, :insert_failed}` drops the database error. Build the struct with `User.changeset/2` and pass the changeset to `Repo.insert/1`. Return `{:error, changeset}` unchanged.

### 6. Option changes the return shape
Rule: Give each function one return shape. Line 30 `if opts[:return_id], do: user.id, else: {:ok, user}` returns an integer in one mode and a tuple in the other. Move it into `import_user_id/2`, which returns `{:ok, id}`.

### 7. Options are not validated or documented, and two booleans overlap
Rule: Use one atom-valued option instead of overlapping booleans; check options with `Keyword.validate!/2` and document them under `## Options`. Line 26 `opts[:notify] && !opts[:silent]` gives a result that depends on which of two flags wins, and a typo in an option name passes silently. Replace them with `welcome: :send | :skip`.

### 8. `&&` and `!` on booleans
Rule: Use `and`, `or`, `not` when the operands are booleans. Line 21 `is_binary(email) && age >= 18` and line 26 `!opts[:silent]` should use `and` and `not`. The `is_binary(email)` check on line 21 also cannot fail, because line 12 already called `String.downcase/1` on it. The changeset replaces both checks.

### 9. Unsupervised `spawn/1`
Rule: Supervise every long-lived process. Line 45 `spawn(fn -> Mailer.deliver(welcome_email(user)) end)` starts a process that no supervisor tracks and that dies silently on error. Use `Task.Supervisor.start_child/2`, and build the email before the closure so the closure captures only the email text. This assumes an `Accounts.TaskSupervisor` is in the supervision tree.

### 10. Pipe into an anonymous function
Rule: Do not pipe into an anonymous function call. Line 51 `greeting |> (fn text -> text <> " Enjoy your account." end).()` is hard to read. Use one string with interpolation.

### 11. Single-step pipe
Rule: Do not pipe a single step. Line 12 `params["email"] |> String.downcase()` is one call. The changeset handles this case, so the line goes away.

### 12. Comments that restate the code or belong in docs
Rule: Comments explain why; documentation goes in `@moduledoc` and `@doc`. Line 2 describes the module and should be `@moduledoc`. Line 5 describes the function and should be `@doc`. Lines 7 (`# Get the role from params`) and 44 (`# send the email`) restate the code and should be deleted. Line 11 explains why and stays.

## Improved version

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.{Repo, User}

  @doc """
  Imports one user from string-keyed params.

  Returns `{:ok, user}` or `{:error, changeset}`. The changeset lists the
  invalid fields.

  ## Options

    * `:welcome` - `:send` emails the user after the insert. `:skip` sends
      nothing. Defaults to `:skip`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, welcome: :skip)

    case insert_user(params) do
      {:ok, user} ->
        if opts[:welcome] == :send, do: send_welcome(user)
        {:ok, user}

      {:error, _changeset} = error ->
        error
    end
  end

  @doc """
  Same as `import_user/2`, but returns `{:ok, id}` instead of the user.
  """
  def import_user_id(params, opts \\ []) do
    case import_user(params, opts) do
      {:ok, user} -> {:ok, user.id}
      {:error, _changeset} = error -> error
    end
  end

  defp insert_user(params) do
    %User{}
    |> User.changeset(params)
    |> Repo.insert()
  end

  defp send_welcome(user) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

## Assumptions about code not in the file

- `User.changeset/2` casts `email`, `age`, `role`, and `nickname`. It lowercases `email`, caps `age` at 120, requires `age >= 18`, and sets `nickname` to the email when no nickname is given.
- The `role` field is an `Ecto.Enum` with a fixed list of values.
- `Accounts.TaskSupervisor` is a `Task.Supervisor` in the application's supervision tree.
- The changes in this version are a behavior change. Underage or invalid users now return `{:error, changeset}` instead of `{:error, :invalid}`, and the age cap is applied in the changeset. Callers that match on the old error atoms must be updated.
- The improved module was not compiled, because it depends on `User` and `Repo`.
