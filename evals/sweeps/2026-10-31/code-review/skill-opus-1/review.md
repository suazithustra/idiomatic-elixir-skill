# Review of `Accounts.UserImporter`

The importer has two bugs that affect users now: welcome emails never go out, and ages above 120 are saved as given. A careless or malicious input file can also crash the whole server, and two imports running at once can get past the duplicate-email check. The improved module below fixes all findings, but it changes what callers get back and needs some setup outside this file. Both are listed after the code.

Line numbers refer to `code-review-input.ex`. Rule names are section headings in `SKILL.md`, or in the reference file named beside them.

## Findings

1. Welcome emails never go out. `user` is a struct (a map with a fixed set of fields), and structs do not support `[]`, so this line raises `UndefinedFunctionError` every time. It runs in the spawned process, so the import still returns success and the only trace is a log entry. Line 53: `name = user[:name] || "there"`. Rule: Read required keys with `map.key` or a pattern; keep `map[:key]` for optional keys. Fix: `name = user.name || "there"`.

2. Input can crash the server. `String.to_atom/1` creates an atom (a named constant Elixir never frees) for each new role string, and the default limit is 1,048,576, so enough distinct values take down the running system. A row with no role also raises to the caller, because this line sits outside the `try`. Line 8: `role = String.to_atom(params["role"])`. Rule: Convert external strings to atoms with explicit clauses, and `Ecto.Enum` under Validate input with changesets in `references/ecto-phoenix.md`. Fix: pass `:role` through `cast/3` on an `Ecto.Enum` field, which accepts only the listed values and returns an error for anything else.

3. Ages above 120 are saved unchanged. The assignment inside the `if` changes only a variable local to that block, and the compiler warns that it is unused. Lines 15-17: `if age > 120 do` and `age = 120`. Rule: Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it. Fix: `update_change(:age, &min(&1, @max_age))`.

4. The duplicate check can be bypassed. Two imports of one email at the same moment can both find no existing user and both insert. A duplicate is also reported as `{:error, :invalid}`, the same as bad input. Line 24: `if Repo.get_by(User, email: email) == nil do`. Rule: Validate input with changesets in `references/ecto-phoenix.md`, which names `unique_constraint/3`. Fix: delete the lookup and add `unique_constraint(:email)`, so the database decides and the caller gets `{:error, changeset}`.

5. System failures are reported as bad input. The blanket `rescue` turns a database outage or a coding bug into `{:error, :invalid}`. Lines 42-43: `rescue` and `_ -> {:error, :invalid}`. Rule: Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs. Fix: remove the `try` and replace `String.to_integer/1` (line 13) with `cast/3`, so bad input returns an error and real failures raise. `cast/3` also accepts the integer ages that JSON (JavaScript Object Notation) sends, which the old code rejected.

6. Input is checked by hand and saved as a raw struct, so required fields are read with `params["..."]` and nothing records which field was wrong. Lines 22 and 25: `user = %User{email: email, age: age, role: role, nickname: nickname}` and `case Repo.insert(user) do`. Rule: Validate input with changesets in `references/ecto-phoenix.md`, and Parse external data into structs where it enters the system. Fix: `import_changeset/1` builds a changeset (Ecto's record of proposed changes and their validation errors) with `cast/3`, `validate_required/2` and `validate_number/3`.

7. An option changes what the function returns: a bare id on success, but a tuple on failure. Line 31: `if opts[:return_id], do: user.id, else: {:ok, user}`. Rule: Give each function one return shape. Fix: remove `:return_id` and always return `{:ok, user}`. Callers read `user.id`.

8. Insert errors are hidden behind one generic result. Lines 33-34: `_ ->` and `{:error, :insert_failed}`. Rule: Match every expected shape and let unexpected ones crash. Fix: `with {:ok, user} <- Repo.insert(import_changeset(params)) do` passes `{:error, changeset}` through, which tells the caller which field failed.

9. The email process has no supervisor, so nothing tracks it or shuts it down in order, and its closure copies the whole user when it needs only the text. Line 49: `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`. Rules: Pick the abstraction that matches the job, Supervise every long-lived process, and Send processes only the data they need, all in `references/processes.md`. Fix: `message = welcome_email(user)`, then `Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(message) end)`.

10. `Mailer` has no alias, so it resolves to a top-level `Mailer` module, and the compiler warned that `Mailer.deliver/1` is undefined in my test project. If no such module exists, emails would still fail after finding 1 is fixed. Line 49: `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`. Rule: the namespace item under Naming, which begins "Put every module under the top-level namespace of its own application or library". Fix: `alias Accounts.{Mailer, Repo, User}`.

11. Two options overlap: `notify: true, silent: true` asks for opposite things. Line 27: `if opts[:notify] && !opts[:silent] do`. Rule: Use one atom-valued field or option instead of overlapping booleans. Fix: keep `:notify` and remove `:silent`.

12. Options and arguments are unchecked, so a misspelled option is silently ignored. Line 6: `def import_user(params, opts \\ []) do`. Rules: Group related parameters, and Make polymorphism explicit in `references/library-design.md`, which covers checks at the public boundary. Fix: `Keyword.validate!(opts, notify: false)`, an `## Options` section in `@doc`, an `is_map(params)` guard, and an `is_boolean(notify)` guard that runs before the insert.

13. The public function has no `@spec`. Line 6: `def import_user(params, opts \\ []) do`. Rule: Add specs, and hide technical functions from the docs in `references/library-design.md`. Fix: `@spec import_user(map(), keyword()) :: {:ok, %User{}} | {:error, Ecto.Changeset.t()}`.

14. `&&` joins two booleans, and `is_binary(email)` can never be false, because line 12 has already raised on a non-string. Line 21: `if is_binary(email) && age >= 18 do`. Rule: Use `and`, `or`, `not` when the operands are booleans. Fix: the condition is gone, replaced by `validate_required/2` and `validate_number/3`.

15. `import_user/2` nests five levels (`try`, `if`, `if`, `case`, `if`), so the reader has to track every branch to see the outcome. Lines 6-45. Rule: Keep functions short and at one level of detail. Fix: split it into `import_user/2`, `insert_user/2`, `import_changeset/1` and `put_default_nickname/1`.

16. Two pipelines break the pipeline rule: one pipes a single step, the other pipes into an anonymous function. Line 12: `email = params["email"] |> String.downcase()`. Line 55: `greeting |> (fn text -> text <> " Enjoy your account." end).()`. Rule: Write pipelines that start with a value and read top to bottom. Fix: `update_change(:email, &String.downcase/1)` and `"Hi #{name}, welcome! Enjoy your account."`.

17. Comments stand in for documentation or restate the code. Lines 2, 5, 7 and 48, for example `# Get the role from params`. Rule: Comments explain why; documentation goes in `@moduledoc` and `@doc`. Fix: lines 2 and 5 become `@moduledoc` and `@doc`, and lines 7 and 48 are deleted. The comment on line 11 gives a reason the code cannot show, so it stays word for word above the lowercasing step.

18. The limits 120 and 18 are unnamed. Lines 15 and 21: `if age > 120 do` and `if is_binary(email) && age >= 18 do`. Rule: the last line of Comments explain why; documentation goes in `@moduledoc` and `@doc`, which reads "Name magic numbers with module attributes". Fix: `@max_age 120` and `@min_age 18`.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  import Ecto.Changeset

  alias Accounts.{Mailer, Repo, User}

  @fields [:email, :age, :role, :nickname]
  @required_fields [:email, :age, :role]
  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from string-keyed `params`.

  `"email"`, `"age"` and `"role"` are required. `"nickname"` defaults to the email. An age
  above #{@max_age} is stored as #{@max_age}. Returns `{:error, changeset}` when a field is
  missing or invalid, the age is under #{@min_age}, or the email is already taken.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.

  ## Examples

      iex> params = %{"email" => "Ada@Example.com", "age" => "36", "role" => "member"}
      iex> {:ok, user} = Accounts.UserImporter.import_user(params)
      iex> user.email
      "ada@example.com"

  """
  @spec import_user(map(), keyword()) :: {:ok, %User{}} | {:error, Ecto.Changeset.t()}
  def import_user(params, opts \\ []) when is_map(params) do
    opts = Keyword.validate!(opts, notify: false)
    insert_user(params, opts[:notify])
  end

  defp insert_user(params, notify) when is_boolean(notify) do
    with {:ok, user} <- Repo.insert(import_changeset(params)) do
      if notify, do: send_welcome(user)
      {:ok, user}
    end
  end

  defp import_changeset(params) do
    %User{}
    |> cast(params, @fields)
    |> validate_required(@required_fields)
    # The provider lowercases addresses before its uniqueness check, so match it here
    |> update_change(:email, &String.downcase/1)
    |> update_change(:age, &min(&1, @max_age))
    |> validate_number(:age, greater_than_or_equal_to: @min_age)
    |> put_default_nickname()
    |> unique_constraint(:email)
  end

  defp put_default_nickname(changeset) do
    nickname = get_field(changeset, :nickname) || get_field(changeset, :email)
    put_change(changeset, :nickname, nickname)
  end

  defp send_welcome(user) do
    message = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(message) end)
  end

  defp welcome_email(user) do
    name = user.name || "there"
    "Hi #{name}, welcome! Enjoy your account."
  end
end
```

## What changes for callers

- Validation failures now return `{:error, %Ecto.Changeset{}}`. Code that matches `{:error, :invalid}` or `{:error, :insert_failed}` must change.
- `:silent`, `:return_id` and any misspelled option now raise `ArgumentError`.
- A database outage or coding bug now raises instead of returning `{:error, :invalid}`, and a missing role now returns an error instead of raising.
- Ages above 120 are stored as 120, integer ages are accepted, and a blank nickname falls back to the email instead of being saved as `""`.

## Needed outside this file

- Add a unique index on `users.email` if there is none: `create unique_index(:users, [:email])`. With the lookup gone, `unique_constraint/3` is the only duplicate check, and without the index duplicates are saved. It expects the default index name, `users_email_index`.
- Confirm `Accounts.User` declares `field :role, Ecto.Enum, values: [...]` with the real roles, and has a `name` field. The file shows neither. Finding 2's protection depends on the `Ecto.Enum` declaration.
- Add `{Task.Supervisor, name: Accounts.TaskSupervisor}` to the application's supervision tree. Without it, `notify: true` exits after the user has been saved.
- Confirm the mailer is `Accounts.Mailer`. If it lives elsewhere, change the alias.
- Run `doctest Accounts.UserImporter` from a test module with database access, because the example inserts a user.

## Left unchanged, for you to check

- The import never sets `name`, so every imported user is greeted "Hi there". I kept `user.name` because `nickname` defaults to the email address, which would read badly in a greeting.
- `Mailer.deliver/1` receives only the message text, with no recipient. The mailer is not in this file, so I kept the call. If it expects an address, build a full email in `welcome_email/1`.
- Any row can set any listed role. If imports must not create admins, add `validate_exclusion(:role, [:admin])`. I did not add it because the role list is not in this file.

## Verification

`mix format --check-formatted` passes and the module compiles without warnings on Elixir 1.20.3. Its 15 tests, including the doctest and concurrent imports of one email, pass against Ecto 3.14 and a SQLite database with a unique index, using stand-in `Accounts.User` and `Accounts.Mailer` modules. Six tests on the original confirmed findings 1, 3, 5 and 7, the rejected integer age, and the raise on a missing role. The race in finding 4 was not reproduced on the original. Nothing was run against the project's real schema or database. The test project was temporary and has been deleted.
