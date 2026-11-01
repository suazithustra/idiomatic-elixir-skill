# Review: `code-review-input.ex`

The import function writes unvalidated data to the database and hides every failure behind a `rescue _` (a catch-all that swallows any error). Its age cap does nothing, and the welcome email is never sent. Findings are ordered by severity.

1. **Invalid data is inserted without validation.** Line 22 builds `%User{email: email, age: age, role: role, nickname: nickname}` and line 25 passes it to `Repo.insert(user)`. Ecto (the database library) inserts a struct as given, so no rule is checked. Rule: `references/ecto-phoenix.md`, section "Validate input with changesets". Fix: put the validations in `User.changeset/2` (shown below) and insert with `%User{} |> User.changeset(params) |> Repo.insert()`.

2. **Errors are hidden by `rescue _`.** Lines 42-43 rescue every exception in the function, so a bug and bad input both return `{:error, :invalid}`. Rule: SKILL.md, section "Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs": "rescue the specific exception, never `rescue _ ->`". Fix: remove the `try`. The parsing is done by `cast/3` in the changeset, which returns errors instead of raising.

3. **The age cap never applies.** Lines 15-17 set `age = 120` inside an `if`. A variable rebound inside `if` stays local to that block, so the outer `age` keeps its value (for example, 150) and the compiler warns. Rule: SKILL.md, section "Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it". Fix: `update_change(:age, &min(&1, @max_age))` in the changeset.

4. **The welcome email is never sent.** Line 53 reads `user[:name]`, but `user` is a `%User{}` struct, and structs do not implement Access (the `user[...]` lookup syntax). The read raises `UndefinedFunctionError` inside the spawned process, so the crash is only logged. The struct also has no `name` field: it has `nickname`. Rule: SKILL.md, section "Read required keys with `map.key` or a pattern; keep `map[:key]` for optional keys", which says structs raise on `user[:name]`. Fix: read `user.nickname` (the changeset fills it with the email when it is not given).

5. **String.to_atom on external input.** Line 8, `String.to_atom(params["role"])`, creates an atom from input. Atoms are never freed and the VM has a fixed limit, so input can crash the node. A nil role also raises here, outside the `try`. Rule: SKILL.md, section "Convert external strings to atoms with explicit clauses". Fix: declare `field :role, Ecto.Enum, values: [...]` in the schema. `Ecto.Enum` casts only the listed values and returns an error for anything else. The values in the example are placeholders for the project's real roles.

6. **Spawned mail process is not supervised.** Line 49, `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`, starts a bare process with no supervisor, so a crash is not reported and nothing restarts it. Rule: `references/processes.md`, section "Supervise every long-lived process". Fix: `Task.Supervisor.start_child(Accounts.TaskSupervisor, ...)`. The supervisor must be added to the application's supervision tree. The fix also builds the email text before the spawn, so the closure captures only the email, not the whole user (`references/processes.md`, section "Send processes only the data they need").

7. **Check-then-insert uniqueness race.** Lines 24-25 check `Repo.get_by(User, email: email) == nil` and then insert. Two imports of the same email can both pass the check. Rule: `references/ecto-phoenix.md` names `unique_constraint/3` for this case. Fix: `unique_constraint(:email)` in the changeset, so a duplicate comes back as `{:error, changeset}`. The migration needs a unique index on `email` for the database to enforce it.

8. **Catch-all clause loses the reason.** Lines 33-34, `_ -> {:error, :insert_failed}`, turn every insert failure, including ones added later, into the same error. Rule: SKILL.md, section "Match every expected shape and let unexpected ones crash". Fix: `with {:ok, user} <- Repo.insert(changeset)`, which passes the `{:error, changeset}` tuple through unchanged.

9. **An option changes the return shape.** Line 31, `if opts[:return_id], do: user.id, else: {:ok, user}`, returns a bare integer in one mode and a tuple in the other. Rule: SKILL.md, section "Give each function one return shape". Fix: remove the `:return_id` option. Callers read `user.id` from the `{:ok, user}` tuple. Callers that pass `return_id:` must change.

10. **Two booleans overlap.** Line 27, `opts[:notify] && !opts[:silent]`, has a meaningless combination (`notify: true, silent: true`). Rule: SKILL.md, section "Use one atom-valued field or option instead of overlapping booleans". Fix: one option, `notify: :welcome | :silent`, defaulting to `:silent`. Callers that pass `notify: true` now send nothing, so they must change to `notify: :welcome`.

11. **`&&` on boolean operands.** Line 21, `is_binary(email) && age >= 18`, uses `&&` where both operands are booleans. Rule: SKILL.md, section "Use `and`, `or`, `not` when the operands are booleans". The `is_binary` check is also dead code, because `String.downcase/1` on line 12 already raises for a non-string. Fix: `validate_required` and `validate_number` in the changeset replace both checks.

12. **Single-step pipe into an anonymous function.** Line 55, `greeting |> (fn text -> text <> " Enjoy your account." end).()`, is a pipe into an anonymous call, which SKILL.md forbids. The same text is built with `<>` where interpolation reads better. Rule: SKILL.md, section "Write pipelines that start with a value and read top to bottom". Fix: one interpolated string in `welcome_email/1`.

13. **Single-step pipe.** Line 12, `params["email"] |> String.downcase()`, pipes one step. Rule: SKILL.md, section "Write pipelines that start with a value and read top to bottom": "Do not pipe a single step". Fix: the lowercasing moves into the changeset as `update_change(:email, &String.downcase/1)`, where the changeset ignores a missing email.

14. **Comments stand in for docs.** Lines 2, 5, 7 and 48 restate the code or describe the module and function in plain comments. Rule: SKILL.md, section "Comments explain why; documentation goes in `@moduledoc` and `@doc`". Fix: `@moduledoc` and `@doc`. The comment on line 11 explains a reason and moves to the changeset.

15. **One function does too much at four levels of nesting.** `import_user/2` nests `try`, `if`, `if`, `case` and `if`. Rule: SKILL.md, section "Keep functions short and at one level of detail". Fix: the public function becomes two steps (insert, then optional email), and the parsing and validation move to the changeset.

## Improved code

`lib/accounts/user_importer.ex`:

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.{Repo, User}

  @doc """
  Imports a single user from string-keyed params.

  Returns `{:ok, user}` on success and `{:error, changeset}` when the params
  are invalid or the email is already taken.

  ## Options

    * `:notify` - `:welcome` sends a welcome email after the insert.
      `:silent` (the default) sends nothing.
  """
  def import_user(params, opts \\ []) do
    changeset = User.changeset(%User{}, params)

    with {:ok, user} <- Repo.insert(changeset) do
      maybe_send_welcome(user, opts[:notify])
      {:ok, user}
    end
  end

  defp maybe_send_welcome(user, :welcome), do: send_welcome(user)
  defp maybe_send_welcome(_user, _silent), do: :ok

  defp send_welcome(user) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

`lib/accounts/user.ex` (the changeset, shown in full for the functions this review relies on; the schema must declare the fields listed in `cast/3`, with `role` as `Ecto.Enum`):

```elixir
defmodule Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @max_age 120

  @doc false
  def changeset(user, attrs) do
    # The provider lowercases addresses before its uniqueness check, so match it here
    user
    |> cast(attrs, [:email, :age, :role, :nickname])
    |> update_change(:email, &String.downcase/1)
    |> update_change(:age, &min(&1, @max_age))
    |> put_default_nickname()
    |> validate_required([:email, :age, :role])
    |> validate_number(:age, greater_than_or_equal_to: 18)
    |> unique_constraint(:email)
  end

  defp put_default_nickname(changeset) do
    if get_field(changeset, :nickname) do
      changeset
    else
      put_change(changeset, :nickname, get_field(changeset, :email))
    end
  end
end
```

Also needed outside these files: `field :role, Ecto.Enum, values: [:admin, :editor, :member]` in the schema (placeholder values), a unique index on `users.email` in a migration, and `{Task.Supervisor, name: Accounts.TaskSupervisor}` in the application's supervision tree.
