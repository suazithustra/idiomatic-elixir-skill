# Review: `Accounts.UserImporter`

References read: `references/processes.md` (for `spawn`) and `references/ecto-phoenix.md` (for `Repo`).

## Findings

### Bugs

1. **Rebinding inside an `if` does not escape it.** Rule: *Assign the result of `if`, `case`, and `Enum` calls*.
   ```elixir
   if age > 120 do
     age = 120
   end
   ```
   The outer `age` keeps its value, so the clamp never happens, and the compiler warns that the inner `age` is unused. Fix: `age = min(age, @max_imported_age)`. In the rewrite this is `update_change(:age, &min(&1, @max_imported_age))` in the changeset.

2. **Reading a struct with `Access`.** Rule: *Read required keys with `map.key`...; structs do not implement `Access`*.
   ```elixir
   name = user[:name] || "there"
   ```
   `user` is a `%User{}`, so `user[:name]` raises `UndefinedFunctionError`. This runs inside the spawned process, so no welcome email is ever sent and nothing reports the failure. The struct built here has no `:name` field. It does have `nickname`, which is always set (it defaults to the email), so the fix is `user.nickname`. If the schema really has a `:name` field, use `user.name` instead.

3. **`String.to_atom/1` on external input.** Rule: *Convert external strings to atoms with explicit clauses*.
   ```elixir
   role = String.to_atom(params["role"])
   ```
   Anyone who controls the import source can exhaust the atom table. The call is also outside the `try`, so a missing `"role"` raises `ArgumentError` from `String.to_atom(nil)` and crashes the caller. Fix: declare `field :role, Ecto.Enum, values: [...]` and let `cast/3` accept only the listed values. The other option is explicit `parse_role/1` clauses.

4. **Building a struct for `Repo.insert/1` bypasses validation.** Rule (ecto-phoenix): *Validate input with changesets*.
   ```elixir
   user = %User{email: email, age: age, role: role, nickname: nickname}
   case Repo.insert(user) do
   ```
   Nothing is validated, and a unique-email violation raises instead of returning an error. Here the `rescue _` swallows it as `:invalid`. Fix: a `User.import_changeset/2` that does `cast`, `validate_required`, `validate_number`, and `unique_constraint(:email)`. The `unique_constraint` assumes a unique index on `email`.

5. **`try/rescue _` around the whole function to get a tuple.** Rule: *Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs*.
   ```elixir
   try do
     ...
     age = String.to_integer(params["age"])
   rescue
     _ -> {:error, :invalid}
   end
   ```
   This turns every exception into `{:error, :invalid}`: a missing email, a non-numeric age, a constraint violation, and real bugs alike. Fix: no `try`. `cast/3` parses the integer without raising, and every failure comes back as `{:error, changeset}` with the reason attached.

6. **`_ ->` catch-all after `{:ok, user}`.** Rule: *Match every expected shape and let unexpected ones crash*.
   ```elixir
   _ ->
     {:error, :insert_failed}
   ```
   This discards the changeset that says why the insert failed. Fix: `{:error, _changeset} = error -> error`.

7. **Unsupervised `spawn` that captures the whole user.** Rules (processes): *Supervise every long-lived process*; *Send processes only the data they need*.
   ```elixir
   spawn(fn -> Mailer.deliver(welcome_email(user)) end)
   ```
   Fix: build the email in the caller and start the task with `Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)`. This needs `{Task.Supervisor, name: Accounts.TaskSupervisor}` in the application's supervision tree.

### API design

8. **Overlapping boolean options.** Rule: *Use one atom-valued field or option instead of overlapping booleans*.
   ```elixir
   if opts[:notify] && !opts[:silent] do
   ```
   `silent: true` only exists to cancel `notify: true`. Fix: keep `:notify` alone and check options with `Keyword.validate!(opts, notify: false)`.

9. **An option changes the return shape.** Rule: *Give each function one return shape*.
   ```elixir
   if opts[:return_id], do: user.id, else: {:ok, user}
   ```
   With `:return_id`, the function returns a bare integer on success and a tuple on failure. Fix: always return `{:ok, user}`. Callers that want the id read `user.id`.

10. **Error reasons that cannot be told apart.** Rule: *Return `{:ok, value}` or `{:error, reason}`...*. Both `{:error, :invalid}` branches hide which field failed. Returning `{:error, changeset}` gives callers per-field errors.

### Readability

11. **`&&` and `!` on booleans.** Rule: *Use `and`, `or`, `not` when the operands are booleans*.
    ```elixir
    if is_binary(email) && age >= 18 do
    ```
    Also, `is_binary(email)` is always true at that point, because `String.downcase/1` has already succeeded or raised. In the rewrite, `validate_required` and `validate_number` replace the whole check.

12. **Comments instead of docs, and comments that restate the code.** Rule: *Comments explain why; documentation goes in `@moduledoc` and `@doc`*.
    ```elixir
    # This module imports users from an external CSV/JSON source
    # Import a single user from the given params
    # Get the role from params
    # send the email
    ```
    Fix: add a `@moduledoc`, plus a `@doc` with `## Options` and an `@spec` on `import_user/2`. Delete the restating comments. The comment `# The provider lowercases addresses...` explains a reason, so it moves with the downcasing into the changeset.

13. **Nested `if` / `case` / `if` in one public function.** Rule: *Keep functions short and at one level of detail*. The rewrite moves the validation into the changeset and keeps `import_user/2` as a short sequence of steps.

14. **Piping a single step.** Rule: *Do not pipe a single step*.
    ```elixir
    email = params["email"] |> String.downcase()
    ```
    Fix: `String.downcase(email)`, which is now `update_change(:email, &String.downcase/1)`.

15. **Piping into an anonymous function call.** Rule: *Do not pipe into an anonymous function call*.
    ```elixir
    greeting |> (fn text -> text <> " Enjoy your account." end).()
    ```
    Fix: build the string in one interpolation: `"Hi #{user.nickname}, welcome! Enjoy your account."`.

16. **Magic number.** Rule: *Name magic numbers with module attributes*. `120` becomes `@max_imported_age 120`.

### Note

- `Mailer` is not aliased and has no namespace, so it resolves to a top-level `Mailer` module. If it is really `Accounts.Mailer`, add it to the alias. I left it unchanged because I can't tell from this file.

## Behaviour changes in the rewrite

- Age is now actually clamped to 120 (finding 1).
- Unknown or missing roles, a missing email, a non-numeric age, and duplicate emails now return `{:error, changeset}`. Before, they either crashed or returned `{:error, :invalid}` / `{:error, :insert_failed}`.
- The `:silent` and `:return_id` options are removed, and `Keyword.validate!/2` raises if a caller still passes them.

## Improved code

`lib/accounts/user_importer.ex`:

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.{Repo, User}

  @doc """
  Imports a single user from string-keyed `params`.

  Returns `{:ok, user}`, or `{:error, changeset}` when the params are invalid
  or the insert violates a database constraint.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)
    changeset = User.import_changeset(%User{}, params)

    case Repo.insert(changeset) do
      {:ok, user} ->
        if Keyword.fetch!(opts, :notify), do: send_welcome(user)
        {:ok, user}

      {:error, _changeset} = error ->
        error
    end
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

The changeset this relies on, added to `Accounts.User`. The schema is not in the input, so the field list and the role values below are assumptions: replace `[:admin, :member]` with the real roles.

```elixir
defmodule Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @max_imported_age 120

  schema "users" do
    field :email, :string
    field :age, :integer
    field :role, Ecto.Enum, values: [:admin, :member]
    field :nickname, :string
  end

  @doc """
  Builds a changeset for a user imported from the external source.
  """
  def import_changeset(user, params) do
    user
    |> cast(params, [:email, :age, :role, :nickname])
    |> validate_required([:email, :age, :role])
    # The provider lowercases addresses before its uniqueness check, so match it here
    |> update_change(:email, &String.downcase/1)
    |> update_change(:age, &min(&1, @max_imported_age))
    |> validate_number(:age, greater_than_or_equal_to: 18)
    |> put_default_nickname()
    |> unique_constraint(:email)
  end

  defp put_default_nickname(changeset) do
    case get_field(changeset, :nickname) do
      nil -> put_change(changeset, :nickname, get_field(changeset, :email))
      _nickname -> changeset
    end
  end
end
```

Verification: both files parse, and `mix format --check-formatted` passes on the importer. The schema file differs only in parentheses on `field`, which comes from formatting outside a project that imports Ecto's formatter config. I did not compile either file because Ecto is not available outside a Mix project.
