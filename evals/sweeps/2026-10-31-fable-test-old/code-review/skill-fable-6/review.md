# Review: `Accounts.UserImporter`

The module imports one user from a string-keyed map and optionally sends a welcome email. As written, it has two bugs a user would notice: two imports of the same email at the same time both pass the duplicate check and the second one is reported as `{:error, :invalid}`, and the welcome email never sends because the email body crashes in a background process that nothing watches. Around those, the module hand-builds what Ecto (the database library) already provides, so most of the fix is to replace the hand-built checks with a changeset.

Each finding below names the rule from the idiomatic-elixir skill, quotes the line, and gives the fix. The improved module at the end applies every one.

## Findings

1. **Lookup before insert instead of a unique constraint** (Ecto reference, "Validate input with changesets"). Line 24, `if Repo.get_by(User, email: email) == nil do`, checks for a duplicate and then inserts. Two concurrent imports of the same address both see no row, the second insert violates the database index and raises, and the `rescue` below reports it as `:invalid`. Fix: declare `unique_constraint(:email)` in the changeset, backed by a unique index, so the second insert returns `{:error, changeset}` with the error on the `:email` field.

2. **A struct built from params is inserted without validation** (Ecto reference, "Validate input with changesets"). Line 22, `user = %User{email: email, age: age, role: role, nickname: nickname}`, is the exact pattern the rule names: Ecto inserts the struct as given, so nothing is validated and a constraint violation raises. Fix: `%User{} |> User.changeset(params) |> Repo.insert()`, with the import-specific rules applied as changeset steps.

3. **`String.to_atom/1` on external input** (rule "Convert external strings to atoms with explicit clauses"). Line 8, `role = String.to_atom(params["role"])`, lets whoever controls the source create one atom per distinct role string, and atoms are never garbage-collected, so the VM (virtual machine) atom table fills up. It also runs outside the `try`, so a missing `"role"` key raises out of the function. Fix: declare `role` as an `Ecto.Enum` field with the accepted values. `cast/3` then turns `"admin"` into `:admin` and rejects anything else with a changeset error.

4. **`try/rescue _ ->` around the whole function** (rule "Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs"). Lines 42 and 43, `rescue` and `_ -> {:error, :invalid}`, turn every exception, including bugs, into the same error tuple. The raising calls inside it, `String.to_integer/1` and `String.downcase/1` on a possibly `nil` email, have non-raising equivalents in the changeset: `cast/3` parses the integer and `validate_required/2` reports the missing key. Fix: drop the `try` and let the changeset carry the errors.

5. **Rebinding inside `if` does not escape the block** (rule "Assign the result of `if`, `case`, and `Enum` calls"). Lines 15 to 17, `if age > 120 do age = 120 end`, assign a variable that is local to the `if`, so the outer `age` is unchanged, the clamp never happens, and the compiler warns about an unused variable. Fix: `update_change(changeset, :age, &min(&1, @max_age))`. I kept the clamp because that is what the code intends; if ages over 120 should be rejected instead, use `validate_number(:age, less_than_or_equal_to: @max_age)`.

6. **`&&` with boolean operands** (rule "Use `and`, `or`, `not` when the operands are booleans"). Line 21, `if is_binary(email) && age >= 18 do`, joins two booleans with `&&`. The first operand is also always `true`, since `String.downcase/1` on line 12 already raised for anything that is not a string. Fix: the age rule becomes `validate_number(:age, greater_than_or_equal_to: @min_age)` and the string check is `validate_required/2` plus the `:string` field type.

7. **`_ ->` after `{:ok, user}` hides the cause** (rule "Match every expected shape and let unexpected ones crash"). Lines 33 and 34, `_ ->` and `{:error, :insert_failed}`, discard the changeset that says which field failed. Together with the three `{:error, :invalid}` returns, every failure reaches the caller as one of two bare atoms. Fix: `{:error, _changeset} = error -> error`, so the caller receives the field errors.

8. **Two overlapping boolean options** (rule "Use one atom-valued field or option instead of overlapping booleans"). Line 27, `if opts[:notify] && !opts[:silent] do`, is the rule's own example: `notify: true, silent: true` makes no sense and one option overrides the other. Fix: keep `:notify` alone.

9. **An option changes the return shape** (rule "Give each function one return shape"). Line 31, `if opts[:return_id], do: user.id, else: {:ok, user}`, returns a bare integer in one mode and a tuple in the other. Fix: remove `:return_id`; a caller that wants the id reads `user.id` from the `{:ok, user}` tuple.

10. **Options are neither checked nor documented** (rules "Group related parameters" and "Comments explain why; documentation goes in `@moduledoc` and `@doc`"). Line 6, `def import_user(params, opts \\ []) do`, accepts any keyword and a misspelled option is silently ignored. Fix: `opts = Keyword.validate!(opts, notify: false)` and an `## Options` section in `@doc`.

11. **Four levels of nested control flow** (rules "Keep functions short and at one level of detail" and "Branch with function clauses and guards before reaching for `if` or `cond`"). Lines 10 to 44 nest `try`, `if`, `if`, `case` and `if`. Fix: one `case` on `Repo.insert(import_changeset(params))`, with the checks as named private steps in a changeset pipeline. There is one fallible call, so the rule "Chain fallible steps with `with`" says `case`, not `with`.

12. **Single-step pipe** (rule "Write pipelines that start with a value and read top to bottom"). Line 12, `email = params["email"] |> String.downcase()`, pipes one step. Fix: `update_change(changeset, :email, &String.downcase/1)`, which also only runs when an email was given. The comment on line 11 explaining why the address is lowercased is a reason the code cannot show, so it stays.

13. **A bare `spawn/1` for fire-and-forget work** (processes reference, "Supervise every long-lived process" and "Pick the abstraction that matches the job"). Line 49, `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`, starts a process no supervisor knows about, so it does not stop on shutdown and does not appear in Observer or LiveDashboard. The closure also captures the whole `user` struct, which is copied into the new process ("Send processes only the data they need"). Fix: build the email in the caller, then `Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)`.

14. **`Access` syntax on a struct** (rule "Read required keys with `map.key` or a pattern; keep `map[:key]` for optional keys"). Line 53, `name = user[:name] || "there"`, raises `UndefinedFunctionError` because structs do not implement `Access`. The raise happens inside the spawned process, so the import reports success and the welcome email never sends. The importer also never sets a `name` field; `nickname` is the field it fills, and it is always set because line 19 defaults it to the email. Fix: `user.nickname`, and drop the `|| "there"` fallback that can never apply.

15. **Pipe into an anonymous function** (rule "Write pipelines that start with a value and read top to bottom"). Line 55, `greeting |> (fn text -> text <> " Enjoy your account." end).()`, is the shape the rule forbids. Fix: one interpolated string, `"Hi #{user.nickname}, welcome! Enjoy your account."`.

16. **Comments in place of documentation, and comments that restate the code** (rule "Comments explain why; documentation goes in `@moduledoc` and `@doc`"). Line 2, `# This module imports users from an external CSV/JSON source`, and line 5, `# Import a single user from the given params`, belong in `@moduledoc` and `@doc`. Line 7, `# Get the role from params`, and line 48, `# send the email`, restate the code. Fix: add `@moduledoc`, `@doc` and `@spec`, delete the four comments, keep line 11.

17. **Magic numbers** (rule "Name magic numbers with module attributes"). Lines 15 and 21 use `120` and `18` inline. Fix: `@max_age 120` and `@min_age 18`.

## Improved code

`mix format --check-formatted` passes on this file unchanged, and it parses. I could not compile it here because Ecto is not installed in this directory.

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.

  The source hands over string-keyed maps. `import_user/2` validates one map
  through `Accounts.User.changeset/2`, applies the import rules the provider
  needs, inserts the user, and optionally sends a welcome email.
  """

  import Ecto.Changeset

  alias Accounts.Mailer
  alias Accounts.Repo
  alias Accounts.User

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from a string-keyed map of params.

  Returns `{:ok, user}` on success and `{:error, changeset}` when a field is
  missing or invalid, the age is under #{@min_age}, or the email is taken.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def import_user(params, opts \\ []) do
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
    |> User.changeset(params)
    |> downcase_email()
    |> clamp_age()
    |> validate_number(:age, greater_than_or_equal_to: @min_age)
    |> put_default_nickname()
  end

  # The provider lowercases addresses before its uniqueness check, so match it here.
  defp downcase_email(changeset), do: update_change(changeset, :email, &String.downcase/1)

  defp clamp_age(changeset), do: update_change(changeset, :age, &min(&1, @max_age))

  defp put_default_nickname(changeset) do
    nickname = get_field(changeset, :nickname) || get_field(changeset, :email)
    put_change(changeset, :nickname, nickname)
  end

  defp send_welcome(user) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user), do: "Hi #{user.nickname}, welcome! Enjoy your account."
end
```

## What the module depends on

The improved importer relies on three things outside the file that the original did not need. Each is a standard piece, but they must exist.

`Accounts.User` must provide a changeset that casts the four fields, requires the three the importer needs, declares `role` as an `Ecto.Enum`, and declares the email constraint. This is the minimum that makes findings 1, 2, 3, 4 and 6 hold:

```elixir
defmodule Accounts.User do
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "users" do
    field :email, :string
    field :age, :integer
    field :role, Ecto.Enum, values: [:admin, :member]
    field :nickname, :string
  end

  def changeset(user, params) do
    user
    |> cast(params, [:email, :age, :role, :nickname])
    |> validate_required([:email, :age, :role])
    |> unique_constraint(:email)
  end
end
```

Replace `[:admin, :member]` with the real role list. `unique_constraint(:email)` needs a unique index on `users.email` in a migration; without the index it does nothing.

`Accounts.TaskSupervisor` must be started in the application's supervision tree as `{Task.Supervisor, name: Accounts.TaskSupervisor}`, above anything that imports users.

`Mailer` is referenced without a namespace in the original. The naming rule puts every module under the application's namespace, so the improved code aliases `Accounts.Mailer`; adjust if the real module lives elsewhere.

## Behaviour changes callers must know about

The error return is now `{:error, %Ecto.Changeset{}}` instead of `{:error, :invalid}` or `{:error, :insert_failed}`. Callers that matched those atoms must match the changeset, and they gain the field that failed.

The `:silent` and `:return_id` options are gone, and `Keyword.validate!/2` raises `ArgumentError` if a caller still passes them, which makes every remaining call site show up on the first run rather than silently misbehave.

A payload that is not a map now raises in `cast/3` instead of being rescued into `:invalid`. That is a caller bug, so raising at the cause is the intended behaviour.
