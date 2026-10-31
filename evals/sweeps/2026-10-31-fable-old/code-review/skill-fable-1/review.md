# Review: `Accounts.UserImporter`

Reviewed against the idiomatic-elixir skill, with its `processes.md`, `ecto-phoenix.md` and `library-design.md` references.

The module has two bugs that matter before style: the welcome email is never sent (finding 14), and the age cap does nothing (finding 5). The rest is the shape the skill's rules describe: a hand-rolled validation and uniqueness check where Ecto changesets do the job, a `try/rescue` that hides every cause behind `{:error, :invalid}`, and an unsupervised `spawn`.

## Findings

1. **Comments instead of `@moduledoc` and `@doc`** (Readability: comments explain why; documentation goes in `@moduledoc` and `@doc`). Lines 2, 5, 7 and 48: `# This module imports users from an external CSV/JSON source`, `# Import a single user from the given params`, `# Get the role from params`, `# send the email` restate the code. Fix: a `@moduledoc` on the module, a `@doc` with an `## Options` section on `import_user/2`, and delete the rest. The one comment that explains a reason, `# The provider lowercases addresses before its uniqueness check, so match it here` (line 11), stays.

2. **`String.to_atom/1` on external input** (Convert external strings to atoms with explicit clauses). Line 8: `role = String.to_atom(params["role"])`. Anyone who controls the source can create unbounded atoms and crash the node, and a missing role raises `FunctionClauseError` outside the `try`. Fix: cast `:role` through the changeset, with `role` declared as `Ecto.Enum` on the `User` schema, so an unknown value becomes a changeset error. If the schema stores role as a string, write `parse_role("admin"), do: {:ok, :admin}` clauses instead.

3. **`try/rescue _ ->` around the whole function** (Return `{:ok, value}` or `{:error, reason}`; raise only for bugs). Lines 10 and 42 to 43: `rescue _ -> {:error, :invalid}`. It turns a missing `"email"`, a non-numeric age and any bug in the body into the same `:invalid`. Fix: drop the `try`, and use calls that return tuples: `cast/3` for the age, `validate_required/2` for missing keys.

4. **Raising call used where a non-raising one exists** (same rule). Line 13: `age = String.to_integer(params["age"])`. Fix: `cast(params, [..., :age, ...])` on an `:integer` field, which records `"is invalid"` on the changeset instead of raising.

5. **Rebinding inside `if` does not escape** (Assign the result of `if`, `case`, and `Enum` calls). Lines 15 to 17: `if age > 120 do age = 120 end`. The outer `age` keeps its value, so the cap never applies, and the compiler warns about an unused variable. Fix, keeping the evident intent to cap: `update_change(:age, &min(&1, @max_age))` in the changeset (or `age = min(age, @max_age)` outside one).

6. **Magic numbers** (Readability: name magic numbers with module attributes). Lines 15 and 21: `120` and `18`. Fix: `@max_age 120` and `@min_age 18`.

7. **Single-step pipe** (Write pipelines that start with a value and read top to bottom). Line 12: `email = params["email"] |> String.downcase()`. Fix: `String.downcase(params["email"])`; in the changeset version it becomes `update_change(:email, &String.downcase/1)`.

8. **`&&` on boolean operands and a dead check** (Use `and`, `or`, `not` when the operands are booleans). Line 21: `if is_binary(email) && age >= 18 do`. Both operands are booleans, so this should be `and`. The `is_binary(email)` test is also dead: `String.downcase/1` on line 12 already raised for anything else. Fix: `validate_number(:age, greater_than_or_equal_to: @min_age)` on the changeset; the type check is `cast/3`'s job.

9. **Hand-built validation of string-keyed params** (Ecto: validate input with changesets; Modeling data: parse external data at the boundary). Lines 12 to 22 read `params["email"]`, `params["age"]`, `params["role"]`, `params["nickname"]` one at a time and build `%User{email: email, age: age, role: role, nickname: nickname}` for `Repo.insert/1`, so Ecto inserts the struct unvalidated. Fix: `%User{} |> cast(params, [:email, :age, :role, :nickname]) |> validate_required([:email, :age, :role])`, with the age and nickname rules as changeset steps. The caller then learns which field failed instead of a bare `:invalid`.

10. **Lookup before insert where `unique_constraint/3` exists** (Ecto: declare database constraints in the changeset). Line 24: `if Repo.get_by(User, email: email) == nil do`. Two concurrent imports both pass the check and the second insert raises. Fix: `unique_constraint(:email)` on the changeset, backed by a unique index, so a duplicate returns `{:error, changeset}`.

11. **Catch-all clause on `Repo.insert/1`** (Match every expected shape and let unexpected ones crash). Lines 33 to 34: `_ -> {:error, :insert_failed}` discards the changeset that says what went wrong. Fix: `{:error, _changeset} = error -> error`.

12. **Overlapping boolean options** (Use one atom-valued field or option instead of overlapping booleans). Line 27: `if opts[:notify] && !opts[:silent] do`. `silent` only overrides `notify`, and `notify: true, silent: true` makes no sense. Fix: keep `:notify` alone, check options with `Keyword.validate!(opts, notify: false)`, and document it under `## Options`.

13. **Option changes the return shape** (Give each function one return shape). Line 31: `if opts[:return_id], do: user.id, else: {:ok, user}`. A caller cannot match the result without knowing the options. Fix: drop `:return_id` and always return `{:ok, user}`; callers read `user.id` from the tuple. A second function returning only the id would add nothing over that.

14. **`Access` on a struct, and a field that does not exist** (Read required keys with `map.key`; structs do not implement `Access`). Line 53: `name = user[:name] || "there"`. `user[:name]` raises `UndefinedFunctionError` on a `%User{}`, and the struct has `nickname`, not `name`. Because this runs inside the spawned process, the crash is silent and no welcome email is ever delivered. Fix: `user.nickname`, which the importer always sets (it defaults to the email), so the `|| "there"` fallback goes too.

15. **Pipe into an anonymous function** (Write pipelines that start with a value). Line 55: `greeting |> (fn text -> text <> " Enjoy your account." end).()`. Fix: one interpolated string, `"Hi #{user.nickname}, welcome! Enjoy your account."`.

16. **Bare `spawn/1` for fire-and-forget work** (Processes: supervise every long-lived process; fire-and-forget work goes through `Task.Supervisor.start_child/2`). Line 49: `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`. The process is invisible to the supervision tree and to tools such as Observer, and its crash is lost, which is why finding 14 went unnoticed. Fix: `Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(message) end)`, with `{Task.Supervisor, name: Accounts.TaskSupervisor}` added to the application's children.

17. **Closure copies the whole struct** (Processes: send processes only the data they need). Same line: the closure captures `user`, so the whole struct is copied into the new process to read one field. Fix: build the message in the caller, `message = welcome_message(user)`, and capture only `message`.

18. **Nested `if` / `case` / `if`, four levels deep** (Keep functions short and at one level of detail). Lines 15 to 41. Fix: `import_user/2` becomes one `case` on `Repo.insert/1`, with the validation in `import_changeset/1` and the nickname default in `put_default_nickname/1`. A `with` is not used because there is one fallible step, so `case` shows both outcomes in one place.

19. **No `@spec` on the public function** (Library design: add specs). Line 6. Fix: `@spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}`, with a guard `when is_map(params)` so a wrong argument fails in this module's own function.

## Assumptions in the improved version

- `Accounts.User` is an Ecto schema with `:email` (string), `:age` (integer), `:nickname` (string) and `:role` declared as `Ecto.Enum`, and defines `@type t`.
- The `users` table has a unique index on `email`.
- `{Task.Supervisor, name: Accounts.TaskSupervisor}` is a child of the application supervisor.
- `Mailer.deliver/1` stays as the original wrote it; it is defined elsewhere.

## Verification

`mix format --check-formatted` passes. The module compiles without warnings under Elixir 1.20.3 against Ecto 3.12 with stub `Repo`, `User` and `Mailer` modules. Exercising it: an age of 130 is stored as 120, the email is lowercased and used as the nickname default, the welcome message is delivered through the task supervisor, an age of 17 with an unknown role yields both changeset errors, and a map with only an invalid age yields `can't be blank` for email and role plus `is invalid` for age.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.

  The source provides string-keyed maps with `"email"`, `"age"`, `"role"` and
  an optional `"nickname"`.
  """

  import Ecto.Changeset

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from the given string-keyed params.

  Returns `{:ok, user}`, or `{:error, changeset}` when a field is missing or
  invalid, or the email is already taken.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def import_user(params, opts \\ []) when is_map(params) do
    opts = Keyword.validate!(opts, notify: false)

    case Repo.insert(import_changeset(params)) do
      {:ok, user} ->
        if opts[:notify], do: send_welcome(user)
        {:ok, user}

      {:error, _changeset} = error ->
        error
    end
  end

  defp import_changeset(params) do
    %User{}
    |> cast(params, [:email, :age, :role, :nickname])
    |> validate_required([:email, :age, :role])
    # The provider lowercases addresses before its uniqueness check, so match it here
    |> update_change(:email, &String.downcase/1)
    |> validate_number(:age, greater_than_or_equal_to: @min_age)
    |> update_change(:age, &min(&1, @max_age))
    |> put_default_nickname()
    |> unique_constraint(:email)
  end

  defp put_default_nickname(changeset) do
    case get_field(changeset, :nickname) do
      nil -> put_change(changeset, :nickname, get_field(changeset, :email))
      _nickname -> changeset
    end
  end

  defp send_welcome(user) do
    message = welcome_message(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(message) end)
  end

  defp welcome_message(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```
