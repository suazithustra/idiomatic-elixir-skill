# Review of `Accounts.UserImporter`

The module builds a `%User{}` by hand and inserts it with no validation. It then wraps everything in `try/rescue`, so real bugs come back as `{:error, :invalid}`. The findings are grouped by theme, with the rule named for each.

## Findings

1. **Atom from external input** (rule: convert external strings to atoms with explicit clauses). `role = String.to_atom(params["role"])` lets anyone who controls the CSV or JSON exhaust the atom table. A missing role raises outside the `try`. Fix: make `role` an `Ecto.Enum` field and `cast/3` it.

2. **`try/rescue _ ->` around the whole function** (rule: return tuples for expected failures; never `rescue _`). It hides a missing `"email"` (`String.downcase(nil)`), a non-numeric age (`String.to_integer/1`), and every other bug as `{:error, :invalid}`. Fix: remove the `try`. The changeset reports bad input as `{:error, changeset}`.

3. **Hand-built struct passed to `Repo.insert/1`, no validation** (ecto-phoenix: validate input with changesets). `%User{email: email, age: age, ...}` skips `cast/3`, `validate_required/2` and `validate_number/3`. Fix: `User.import_changeset/1`, shown below.

4. **Lookup before insert** (rule: declare constraints in the changeset). `if Repo.get_by(User, email: email) == nil` has a race: two imports can both pass the check and one insert then raises. Fix: `unique_constraint(:email)`. This needs a unique index on the lowercased email in the database.

5. **Rebinding inside `if` does not escape it.** `if age > 120 do age = 120 end` changes nothing. The compiler warns that `age` is unused, and an age of 500 is still imported. Fix: `update_change(:age, &min(&1, @max_age))`, with `@max_age` as a named attribute.

6. **Magic numbers** (`120`, `18`). Named as `@max_age` and `@min_age`.

7. **`&&` and `!` on booleans** (rule: use `and`, `or`, `not` for booleans). `is_binary(email) && age >= 18` and `opts[:notify] && !opts[:silent]`. `is_binary(email)` was also useless, because `String.downcase/1` had already run on it.

8. **Overlapping booleans** (`notify` and `silent`). `notify: true, silent: true` makes no sense. Fix: one option, `:notify`, checked with `Keyword.validate!/2` and documented under `## Options`.

9. **Option changes the return shape** (rule: one return shape per function). `return_id: true` returns a bare `user.id`, otherwise `{:ok, user}`. Fix: remove the option. Callers who want the id read `user.id` from `{:ok, user}`. This is a behavior change for any caller that uses `return_id`.

10. **`_ -> {:error, :insert_failed}`** (rule: match every expected shape). It discards the changeset errors. The new code matches `{:error, %Ecto.Changeset{}}` and passes it through.

11. **Nested `if`/`case`/`if`** (rule: keep functions short, one level of detail). `import_user/2` was five levels deep. It is now a single `case` with the work in `insert_user/1` and `send_welcome/1`.

12. **Bare `spawn/1`** (processes: supervise every long-lived process; send only the data needed). The delivery process is unsupervised, so a crash in it goes unreported. The closure also captures the whole `user`. Fix: build the email first, then `Task.Supervisor.start_child/2` with a closure that captures only `email`. `Accounts.TaskSupervisor` must be in the application's supervision tree.

13. **`user[:name]` on a struct** (rule: structs do not implement `Access`). It raises `UndefinedFunctionError`, so the welcome email never sent. The `|| "there"` fallback could never run. Fix: read a field with a dot. I used `user.nickname`, which the changeset always fills, but this is my guess. If `User` has a `name` field, use that instead.

14. **Pipe into an anonymous function** (`|> (fn text -> ... end).()`) and string concatenation with `<>`. Replaced with one interpolated string.

15. **Comments that restate code and docs as comments** (`# Get the role from params`, `# send the email`, `# Import a single user ...`). Deleted. The explanation of the downcase now lives in the changeset, and the docs are in `@moduledoc` and `@doc`. I added `@spec`.

16. **Smaller points.** `params["email"] |> String.downcase()` was a single-step pipe. The `alias` block now follows `@moduledoc`. `Mailer` is unqualified, so check it sits under your app's namespace.

## Behavior changes to check

- Errors are `{:error, %Ecto.Changeset{}}`, not `{:error, :invalid}` or `{:error, :insert_failed}`. Callers that match the old atoms need updating.
- The age of 120 is clamped as the original intended. The original code never actually clamped.
- `nickname` defaults to the lowercased email, as before.

## Improved code

I could not run `mix format` or compile it here (the sandbox blocked writing scratch files), and the module depends on Ecto and your `Repo`. Run `mix format` and compile before use.

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.{Repo, User}

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

    case insert_user(params) do
      {:ok, user} ->
        if opts[:notify], do: send_welcome(user)
        {:ok, user}

      {:error, %Ecto.Changeset{}} = error ->
        error
    end
  end

  defp insert_user(params) do
    params
    |> User.import_changeset()
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

Add this to `Accounts.User` (the role values are placeholders; use your real ones):

```elixir
defmodule Accounts.User do
  use Ecto.Schema

  import Ecto.Changeset

  @max_age 120
  @min_age 18

  schema "users" do
    field :email, :string
    field :age, :integer
    field :role, Ecto.Enum, values: [:admin, :member]
    field :nickname, :string
  end

  def import_changeset(params) do
    %__MODULE__{}
    |> cast(params, [:email, :age, :role, :nickname])
    |> validate_required([:email, :age, :role])
    # The provider lowercases addresses before its uniqueness check, so match it here
    |> update_change(:email, &String.downcase/1)
    |> update_change(:age, &min(&1, @max_age))
    |> validate_number(:age, greater_than_or_equal_to: @min_age)
    |> default_nickname()
    |> unique_constraint(:email)
  end

  defp default_nickname(changeset) do
    if get_field(changeset, :nickname) do
      changeset
    else
      put_change(changeset, :nickname, get_field(changeset, :email))
    end
  end
end
```
