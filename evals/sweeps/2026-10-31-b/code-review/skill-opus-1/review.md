# Review of `Accounts.UserImporter`

A bad input file can crash the server through this module. It also never sends its welcome email, does not apply its age limit, can store one email address twice, and rejects every JSON (JavaScript Object Notation) row that gives the age as a number. The improved version below fixes these and every other finding. It needs three changes outside this module and it changes what callers get back; both are listed after the code.

Line numbers refer to `code-review-input.ex`. Rule names are headings from `SKILL.md` unless another file is named.

## Findings

### Bugs

1. A crafted input file can crash the server. Each new role value creates an atom (a named constant that is never freed), and the virtual machine stops at about one million of them. A missing role also raises instead of returning an error, because this line runs before the `try`. Line 8: `role = String.to_atom(params["role"])`. Fix: declare `field :role, Ecto.Enum, values: [:admin, :member]` so `cast/3` accepts only listed values and creates no atoms. Rule: Convert external strings to atoms with explicit clauses.

2. No welcome email is ever sent. `user` is a struct, and structs do not support `[:name]`, so this line raises. It raises inside the spawned process, so `import_user` still returns `{:ok, user}` and only the log shows the failure. Line 53: `name = user[:name] || "there"`. Fix: `name = user.name || "there"`. Rule: Read required keys with `map.key` or a pattern; keep `map[:key]` for optional keys.

3. The age limit does nothing: an age of 200 is stored as 200. Assigning inside an `if` block does not change the variable outside it, and the compiler warns about this. Line 16: `age = 120`. Fix: `update_change(:age, &min(&1, @maximum_age))`. Rule: Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it.

4. Two imports running at the same time can both find no existing user and both insert, which gives one address two rows. Line 24: `if Repo.get_by(User, email: email) == nil do`. Fix: remove the lookup, add `unique_constraint(:email)` to the changeset (Ecto's record of validated changes) and a unique index to the table. The database then decides, and a duplicate returns `{:error, changeset}`. Rule: Validate input with changesets (`references/ecto-phoenix.md`).

5. The record is built directly from the input and inserted, so nothing checks it, and a constraint violation raises instead of returning an error. Lines 22 and 25: `user = %User{email: email, age: age, role: role, nickname: nickname}` and `case Repo.insert(user) do`. Fix: `%User{} |> User.import_changeset(params) |> Repo.insert()`. Rule: Validate input with changesets (`references/ecto-phoenix.md`).

6. Ages sent as JSON numbers are rejected, although the module says it reads JSON. `String.to_integer/1` takes only a string, so `30` raises and the row fails. Bad text such as `"abc"` also fails only by raising. Line 13: `age = String.to_integer(params["age"])`. Fix: `cast/3` on an `:integer` field accepts `"30"` and `30`, and returns an error for `"abc"`. Rule: Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs.

7. The `rescue` reports every failure as bad input, including database outages and programming mistakes, so real faults look like bad rows. Lines 10 and 42 to 43: `try do`, `rescue`, `_ -> {:error, :invalid}`. Fix: delete the `try`. Validation now returns errors for bad input, and real faults raise. Rule: Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs.

8. The catch-all turns every other insert result into one error and drops the reason. Lines 33 to 34: `_ ->` and `{:error, :insert_failed}`. Fix: `with {:ok, user} <- insert_user(params) do`, which passes `{:error, changeset}` through unchanged. Rule: Match every expected shape and let unexpected ones crash.

### Design

9. Every failure comes back as `{:error, :invalid}`, so a caller cannot tell a missing email from a duplicate one. Required fields are read with `params["key"]` and rely on a raise when absent. Lines 12 and 13: `email = params["email"] |> String.downcase()` and `age = String.to_integer(params["age"])`. Fix: `validate_required([:email, :age, :role])`, which names each failing field in the changeset. Rule: Parse external data into structs where it enters the system.

10. One option changes the return type: a bare ID on success and a tuple on failure. Line 31: `if opts[:return_id], do: user.id, else: {:ok, user}`. Fix: remove `:return_id` and always return `{:ok, user}`. A second function is not needed because callers can read `user.id`. Rule: Give each function one return shape.

11. `:notify` and `:silent` overlap, and `notify: true, silent: true` has no sensible meaning. Misspelled options are also ignored without any error. Line 27: `if opts[:notify] && !opts[:silent] do`. Fix: keep `:notify` only, with `opts = Keyword.validate!(opts, notify: false)` and `if opts[:notify], do: send_welcome(user)`. Rules: Use one atom-valued field or option instead of overlapping booleans; Group related parameters.

12. Nothing owns a bare `spawn`: shutdown does not wait for it and a crash appears only in the log. Line 49: `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`. Fix: `Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(message) end)`. Rule: Supervise every long-lived process (`references/processes.md`).

13. The new process receives a copy of the whole `user` to build one string. Line 49: `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`. Fix: `message = welcome_email(user)` before starting the task, so the task holds only `message`. Rule: Send processes only the data they need (`references/processes.md`).

### Readability

14. `&&` is for truthy values and both sides here are booleans. `is_binary(email)` also can never be false at this point, because `String.downcase/1` on line 12 has already raised for anything else. Line 21: `if is_binary(email) && age >= 18 do`. Fix: `validate_required/2` and `validate_number/3` replace the condition; a remaining boolean check would use `and`. Rule: Use `and`, `or`, `not` when the operands are booleans.

15. The limits have no names. Lines 15 and 21: `if age > 120 do` and `if is_binary(email) && age >= 18 do`. Fix: `@maximum_age 120` and `@minimum_age 18`. Rule: Comments explain why; documentation goes in `@moduledoc` and `@doc` (the magic-number sentence under that heading).

16. The logic is nested five levels deep (`try`, `if`, `if`, `case`, `if`), so it is hard to see which `else` answers which check. Lines 10 to 44, starting at `try do`. Fix: `import_user/2` becomes one `with` over `insert_user/1`, and validation moves into the changeset. Rule: Keep functions short and at one level of detail.

17. A pipe with one step adds nothing. Line 12: `email = params["email"] |> String.downcase()`. Fix: `update_change(:email, &String.downcase/1)`. Rule: Write pipelines that start with a value and read top to bottom.

18. Piping into an anonymous function takes three steps to join one string. Lines 54 to 55: `greeting = "Hi " <> name <> ", welcome!"` and `greeting |> (fn text -> text <> " Enjoy your account." end).()`. Fix: `"Hi #{name}, welcome! Enjoy your account."`. Rule: Write pipelines that start with a value and read top to bottom.

19. The module and function descriptions are comments, so generated documentation omits them, and no option is documented. Lines 2 and 5: `# This module imports users from an external CSV/JSON source` and `# Import a single user from the given params`. Fix: `@moduledoc`, and `@doc` with an `## Options` section. Rule: Comments explain why; documentation goes in `@moduledoc` and `@doc`.

20. Two comments repeat the code. Lines 7 and 48: `# Get the role from params` and `# send the email`. Fix: delete them. The comment on line 11, `# The provider lowercases addresses before its uniqueness check, so match it here`, gives a reason the code cannot show, so it stays beside the `update_change` call. Rule: Comments explain why; documentation goes in `@moduledoc` and `@doc`.

21. The public function has no `@spec` and does not check its input type. Line 6: `def import_user(params, opts \\ []) do`. Fix: add the `@spec` and `when is_map(params)`. Rules: Add specs, and hide technical functions from the docs; Make polymorphism explicit (both `references/library-design.md`).

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.{Repo, User}

  @doc """
  Imports a single user from string-keyed `params`.

  Returns `{:ok, user}`, or `{:error, changeset}` when a field is missing or
  invalid, or when the email is already taken.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  @spec import_user(map(), keyword()) :: {:ok, %User{}} | {:error, Ecto.Changeset.t()}
  def import_user(params, opts \\ []) when is_map(params) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, user} <- insert_user(params) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  defp insert_user(params) do
    %User{}
    |> User.import_changeset(params)
    |> Repo.insert()
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

`Accounts.User` was not part of the input. The field list below is inferred from the code, so keep your real schema and add the `role` type, the two attributes, `import_changeset/2` and its helper.

```elixir
defmodule Accounts.User do
  use Ecto.Schema

  import Ecto.Changeset

  @minimum_age 18
  @maximum_age 120

  schema "users" do
    field :email, :string
    field :age, :integer
    field :role, Ecto.Enum, values: [:admin, :member]
    field :name, :string
    field :nickname, :string
  end

  @doc """
  Builds the changeset for a user read from an external source.

  This is separate from any form changeset because it casts `:role`, which only
  an import may set.
  """
  @spec import_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def import_changeset(user, params) do
    user
    |> cast(params, [:email, :age, :role, :nickname])
    |> validate_required([:email, :age, :role])
    # The provider lowercases addresses before its uniqueness check, so match it here
    |> update_change(:email, &String.downcase/1)
    |> update_change(:age, &min(&1, @maximum_age))
    |> validate_number(:age, greater_than_or_equal_to: @minimum_age)
    |> put_default_nickname()
    |> unique_constraint(:email)
  end

  defp put_default_nickname(changeset) do
    nickname = get_field(changeset, :nickname) || get_field(changeset, :email)
    put_change(changeset, :nickname, nickname)
  end
end
```

## Changes needed outside this module

- `Accounts.User`: add the code above. `[:admin, :member]` is a placeholder, because the input does not show the real roles. `import_changeset/2` is separate from a shared `changeset/2` so that a signup form cannot set its own role, and so the age and email rules still apply only to imports.
- Migration: `create unique_index(:users, [:email])`. Remove any existing duplicate addresses first, or the migration fails.
- Supervision tree: add `{Task.Supervisor, name: Accounts.TaskSupervisor}` before anything that calls the importer.

## Changes for callers

- Failures now return `{:error, changeset}`, not `{:error, :invalid}` or `{:error, :insert_failed}`.
- `silent:` and `return_id:` now raise `ArgumentError`. Replace `notify: true, silent: true` by leaving out `notify`, and replace `return_id: true` by matching `{:ok, user}` and reading `user.id`.
- Ages over 120 are stored as 120, and JSON number ages are accepted.
- An empty nickname now falls back to the email address, where it used to be stored as `""`.
- A missing role now returns an error, where it used to raise.

## Still open

The welcome email code has never run past line 53, so the call to `Mailer.deliver/1` is unproven, and this fix makes it run for the first time. It receives only text with no recipient address, and `Mailer` is not aliased, so it means a top-level `Mailer`, not `Accounts.Mailer`. I left the call as it was because `Mailer` is not in the input. Check both points before using `notify: true`.

`user.name` needs a `name` field on `User`, which the input does not show. The importer never sets it, so the greeting says "Hi there" unless `User` supplies a value. If the field does not exist, `notify: true` raises `KeyError` after the insert. I kept `name` rather than `nickname` because `nickname` falls back to the email address, which would put the address in the greeting.

`role` is still taken from the input, as before, so any row can say `admin`. If the source is not fully trusted, I would remove `:role` from `cast/3` and set it in code.

## Verification

Both improved modules compile without warnings and pass `mix format --check-formatted`. I ran the original and improved code side by side on SQLite (a file-based database) with a stand-in `Mailer`. Findings 1 to 4 and 6 reproduced on the original and not on the improved version, including 16 concurrent imports storing 8 rows for one address when no unique index exists, and 1 row with the fix and index. The real `User`, `Mailer` and production database were not available, and I wrote no ExUnit tests.
