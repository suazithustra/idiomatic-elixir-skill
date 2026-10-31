# Review: `Accounts.UserImporter`

## Findings

1. Ages above 120 are never capped. Line 15 reads `if age > 120 do`, then `age = 120` inside the block. A variable set inside an `if` does not leave the block, so the outer `age` keeps its value. The fix is `age = min(age, @max_age)`, with the 18 and 120 limits moved into module attributes (rule: assign the result of `if`, `case`, and `Enum` calls; name magic numbers).

2. Welcome emails crash. Line 53 reads `user[:name] || "there"`. `%User{}` is a struct (a map with a fixed set of named fields), and structs do not support `[]` access, so this raises `UndefinedFunctionError`. The schema has no `name` field either; its fields are `email`, `age`, `role`, and `nickname`. The fix greets with `user.nickname`, which is always set because it defaults to the email (rule: read required keys with `map.key`; structs do not implement `Access`).

3. Role input can exhaust the atom table. Line 8 reads `String.to_atom(params["role"])`. Atoms are never freed, and the Erlang VM (the runtime Elixir runs on) has a fixed limit on them, so a stream of made-up role strings can crash the node. A missing role also raises here, outside the `try`. The fix is `parse_role/1`, which checks the value against a list of accepted roles (rule: convert external strings to atoms with explicit clauses). The role names in `@roles` are placeholders; use the ones the `User` schema defines.

4. A catch-all `rescue` hides every bug. Lines 10 and 42–44 wrap the whole body in `try ... rescue _ -> {:error, :invalid}`. A typo in this code becomes "invalid input". The rescue also covers `String.to_integer(params["age"])` on line 13, which raises on text such as `"abc"`. The fix uses `Integer.parse/1` with a pattern match and removes the `try` (rule: return tuples for expected failures; raise only for bugs). The body also nests `case` and `if` inside `if` inside `try`; the rewrite splits it into named steps chained with `with` (rule: keep functions short and at one level of detail).

5. Every failure returns the same reason. Lines 37, 40, and 43 all return `{:error, :invalid}`, so a caller cannot tell a missing email from an underage user or a taken email. The fix returns a distinct reason for each case, such as `{:error, {:missing_field, "email"}}`, `{:error, :underage}`, and `{:error, :email_taken}` (rule: use atoms and tagged tuples as error reasons).

6. A catch-all clause hides insert errors. Lines 33–34 read `_ -> {:error, :insert_failed}`. Any other return value from `Repo.insert/1`, including one added later, becomes the same error. The fix matches `{:error, changeset}` and passes the changeset on (rule: match every expected shape and let unexpected ones crash).

7. The duplicate check is a race, and the insert skips validation. Line 24 reads `if Repo.get_by(User, email: email) == nil do`, and line 25 inserts a bare `%User{}`. Two imports of the same address can both pass the check before either inserts. Nothing is validated, and a database constraint violation raises instead of returning an error. The fix casts and validates through `User.changeset/2`, declares `unique_constraint(:email)`, adds a unique index on `users.email`, and maps the constraint error to `:email_taken`. Ecto (the Elixir database library) returns that error as a value (rule: changesets and `unique_constraint/3`, from the Ecto and Phoenix reference). See the companion changeset below.

8. Two overlapping booleans control the welcome email. Line 27 reads `if opts[:notify] && !opts[:silent] do`. `silent` only cancels `notify`, and the call `notify: true, silent: true` means nothing useful. The options are also not checked, so a misspelled key passes silently. The fix replaces both with one option, `welcome: :email | :none`, checked with `Keyword.validate!/2` (rule: use one atom-valued option instead of overlapping booleans). Callers that pass `notify:` or `silent:` must change.

9. One function returns two shapes. Line 31 reads `if opts[:return_id], do: user.id, else: {:ok, user}`, so callers get a bare integer or a tuple depending on an option. The fix moves the id return into `import_user_id/2`, which returns `{:ok, id}` (rule: give each function one return shape).

10. `&&` is used on booleans. Line 21 reads `if is_binary(email) && age >= 18 do`. Both operands are booleans, so `and` is the right operator. `&&` accepts any value and hides a mistake. The fix removes the line: the checks move into `parse_email/1` and `check_adult/1`, which return tuples (rule: use `and`, `or`, `not` for booleans).

11. The welcome email runs in an unsupervised process. Line 49 reads `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`. If the process crashes, nothing restarts it and no supervisor reports it. The fix uses `Task.Supervisor.start_child/2` under `Accounts.TaskSupervisor`, which the application must start in its supervision tree. The closure now captures only the built email, not the whole flow (rule: supervise every long-lived process; send processes only the data they need).

12. A pipe runs into an anonymous function. Line 55 reads `greeting |> (fn text -> text <> " Enjoy your account." end).()`. The fix builds the whole text in one interpolated string (rule: do not pipe into an anonymous function).

13. A one-step pipe. Line 12 reads `params["email"] |> String.downcase()`. The fix calls `String.downcase(email)` inside `parse_email/1` (rule: do not pipe a single step).

14. Comments restate the code, and the module comment is in the wrong place. Lines 2 and 5 describe the module and a function, which belong in `@moduledoc` and `@doc`. Lines 7 and 48 repeat what the next line says and are removed. Line 11 gives a reason the code cannot show, so it stays (rule: comments explain why; documentation goes in `@moduledoc` and `@doc`).

## Improved code

Written to `lib/accounts/user_importer.ex`. Assumptions: `User.changeset/2` exists (see below), `Accounts.TaskSupervisor` is started by the application, and `@roles` matches the roles `User` defines.

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV (comma-separated values) or JSON source.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120
  @roles [:admin, :editor, :member]

  @doc """
  Imports a single user from the given params.

  Returns `{:ok, user}` or `{:error, reason}`.

  ## Options

    * `:welcome` - `:email` sends a welcome email after the insert, `:none` sends nothing. Defaults to `:none`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, welcome: :none)

    with {:ok, attrs} <- parse_attrs(params),
         {:ok, user} <- insert_user(attrs) do
      maybe_send_welcome(user, opts[:welcome])
      {:ok, user}
    end
  end

  @doc """
  Same as `import_user/2`, but returns `{:ok, id}` instead of the user.
  """
  def import_user_id(params, opts \\ []) do
    with {:ok, user} <- import_user(params, opts), do: {:ok, user.id}
  end

  defp parse_attrs(params) do
    with {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         {:ok, role} <- parse_role(params["role"]),
         :ok <- check_adult(age) do
      attrs = %{
        email: email,
        age: min(age, @max_age),
        role: role,
        nickname: params["nickname"] || email
      }

      {:ok, attrs}
    end
  end

  # The provider lowercases addresses before its uniqueness check, so match it here
  defp parse_email(nil), do: {:error, {:missing_field, "email"}}
  defp parse_email(email) when is_binary(email), do: {:ok, String.downcase(email)}
  defp parse_email(_email), do: {:error, {:invalid_field, "email"}}

  defp parse_age(nil), do: {:error, {:missing_field, "age"}}

  defp parse_age(text) when is_binary(text) do
    case Integer.parse(text) do
      {age, ""} -> {:ok, age}
      {_age, _rest} -> {:error, {:invalid_field, "age"}}
      :error -> {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(_age), do: {:error, {:invalid_field, "age"}}

  defp parse_role(nil), do: {:error, {:missing_field, "role"}}

  defp parse_role(name) when is_binary(name) do
    case Enum.find(@roles, &(Atom.to_string(&1) == name)) do
      nil -> {:error, {:invalid_field, "role"}}
      role -> {:ok, role}
    end
  end

  defp parse_role(_name), do: {:error, {:invalid_field, "role"}}

  defp check_adult(age) when age >= @min_age, do: :ok
  defp check_adult(_age), do: {:error, :underage}

  defp insert_user(attrs) do
    case Repo.insert(User.changeset(%User{}, attrs)) do
      {:ok, user} -> {:ok, user}
      {:error, changeset} -> {:error, insert_error(changeset)}
    end
  end

  defp insert_error(changeset) do
    if email_taken?(changeset), do: :email_taken, else: {:invalid_user, changeset}
  end

  defp email_taken?(changeset) do
    match?({_message, [constraint: :unique | _]}, Keyword.get(changeset.errors, :email))
  end

  defp maybe_send_welcome(user, :email), do: send_welcome(user)
  defp maybe_send_welcome(_user, :none), do: :ok

  defp send_welcome(user) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

## Companion: `User.changeset/2`

The importer depends on this changeset. The `users.email` column also needs a unique index in its migration, or `unique_constraint/3` never fires.

```elixir
def changeset(user, attrs) do
  user
  |> cast(attrs, [:email, :age, :role, :nickname])
  |> validate_required([:email, :age, :role])
  |> unique_constraint(:email)
end
```

`role` should be an `Ecto.Enum` field so that `cast/3` accepts the atoms `parse_role/1` returns.
