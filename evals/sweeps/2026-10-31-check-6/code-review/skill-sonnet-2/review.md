# Review: `Accounts.UserImporter`

## Findings

1. **Bug: the age cap does nothing** (Rebinding inside a block). `if age > 120 do age = 120 end` rebinds `age` only inside the `if`. Ages above 120 pass through unchanged, and the compiler warns about an unused variable. Fix: clamp in the changeset with `update_change(:age, &min(&1, @max_age))`.

2. **Atom exhaustion** (Convert external strings to atoms with explicit clauses). `role = String.to_atom(params["role"])` lets anyone who controls the input fill the VM's (virtual machine's) atom table. A missing role raises `ArgumentError`. Fix: make `role` an `Ecto.Enum` field and cast it in the changeset.

3. **`try/rescue` around the whole function** (Return tuples for expected failures; never `rescue _ ->`). `rescue _ -> {:error, :invalid}` hides every bug, including bugs in the code below. It exists only to catch `String.to_integer/1` and `String.downcase(nil)`. Fix: no `rescue`. Changeset casting returns errors for bad input instead of raising.

4. **Hand-built validation instead of a changeset** (Ecto/Phoenix: validate input with changesets). `%User{email: ..., age: ...}` passed to `Repo.insert/1` skips validation. The `age >= 18` and `is_binary(email)` checks are written by hand. Fix: `User.import_changeset/2` with `cast/3`, `validate_required/2` and `validate_number/3`. The `is_binary(email)` check is also dead code, because `String.downcase/1` has already raised on a non-binary.

5. **Lookup before insert is a race** (`unique_constraint/3`). `Repo.get_by(User, email: email) == nil` followed by `Repo.insert/1` lets two imports of one email both pass the check, and the second insert raises. Fix: `unique_constraint(:email)` in the changeset, so the duplicate returns `{:error, changeset}`.

6. **Catch-all error clause** (Match every expected shape). `_ -> {:error, :insert_failed}` and the repeated `{:error, :invalid}` hide the cause: the caller cannot tell a bad age from a duplicate email. Fix: return `{:error, changeset}`, which names the field and the reason.

7. **Overlapping booleans and a mode that changes the return shape** (One atom-valued option; one return shape). `notify` and `silent` can contradict each other. `return_id` makes the function return either `user.id` or `{:ok, user}`. Fix: keep only `:notify`, and validate the options with `Keyword.validate!/2`. Callers read `user.id` from `{:ok, user}`.

8. **`&&` and `!` on booleans** (Use `and`, `or`, `not`). `is_binary(email) && age >= 18` is gone with finding 4. `opts[:notify] && !opts[:silent]` is gone with finding 7.

9. **Nested `if`/`case`/`if`, five levels deep** (Keep functions short; use `with`). Replaced by one `with` step on `Repo.insert/1`, with validation in the changeset. The body is two expressions, so it is a block.

10. **Unsupervised `spawn/1`, and the closure copies `user`** (processes.md: supervise every long-lived process; send processes only the data they need). If the mail delivery crashes, nothing restarts or reports it. The closure also copies the whole `user` struct. Fix: build the email first, then `Task.Supervisor.start_child/2` with a closure that captures only the email. This assumes `{Task.Supervisor, name: Accounts.TaskSupervisor}` is in the supervision tree.

11. **`user[:name]` on a struct** (Structs don't implement `Access`). It raises `UndefinedFunctionError`. The `%User{}` built here has no `name` set anyway. Fix: use `user.nickname`, which the importer always sets.

12. **Piping into an anonymous function** (`|> (fn ... end).()`). Replaced by one interpolated string.

13. **Missing `@moduledoc`, `@doc`, `@spec`; restating comments; unnamespaced `Mailer`** (Comments explain why; Put every module under the application's namespace). `# Import a single user...`, `# Get the role...` and `# send the email` restate the code and are deleted. The documentation moves into `@moduledoc` and `@doc` with an `## Options` section. The one comment that gives a reason (the provider lowercases addresses before its uniqueness check) moves to the changeset. `Mailer` is aliased as `Accounts.Mailer`, which is an assumption.

14. **Alias order and grouping.** `alias Accounts.{Repo, User}` is split into one alias per line, after `@moduledoc`.

## Assumptions

`User.import_changeset/2` does not exist in the input, so the second block adds it. `User.role` must be an `Ecto.Enum`, and the schema needs `@type t`. The `Accounts.Mailer` and `Accounts.TaskSupervisor` names are guesses. I did not compile or run any of this, because the `User` schema and `Repo` are not available.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.Mailer
  alias Accounts.Repo
  alias Accounts.User

  @doc """
  Imports a single user from string-keyed `params`.

  Returns `{:ok, user}`, or `{:error, changeset}` when the params are invalid
  or the email is already taken.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)
    changeset = User.import_changeset(%User{}, params)

    with {:ok, user} <- Repo.insert(changeset) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
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

Added to `Accounts.User` (with `import Ecto.Changeset`, `field :role, Ecto.Enum, values: [...]`):

```elixir
@max_age 120

def import_changeset(user, params) do
  user
  |> cast(params, [:email, :age, :role, :nickname])
  |> validate_required([:email, :age, :role])
  # The provider lowercases addresses before its uniqueness check, so match it here
  |> update_change(:email, &String.downcase/1)
  |> update_change(:age, &min(&1, @max_age))
  |> validate_number(:age, greater_than_or_equal_to: 18)
  |> put_default_nickname()
  |> unique_constraint(:email)
end

defp put_default_nickname(changeset) do
  case get_field(changeset, :nickname) do
    nil ->
      put_change(changeset, :nickname, get_field(changeset, :email))

    _nickname ->
      changeset
  end
end
```
