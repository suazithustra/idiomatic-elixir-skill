# Review: `Accounts.UserImporter`

The module has two real bugs (the age cap is a no-op, and every welcome email crashes before it is sent), a race between the duplicate check and the insert, and an unbounded atom leak from the role field. The rest is readability. The improved version at the end moves validation into an Ecto changeset, which removes most of the code the findings are about.

## Findings

1. **Convert external strings to atoms with explicit clauses.** Line 8, `role = String.to_atom(params["role"])`, creates a new atom for every distinct role string the source sends, and atoms are never collected, so a bad feed can exhaust the atom table and crash the node. It also runs outside the `try`, so a missing role raises `ArgumentError` instead of returning an error. Fix: declare `field :role, Ecto.Enum, values: [...]` on the schema and let `cast/3` convert the string; an unknown or missing role becomes a changeset error.

2. **Validate input with changesets (Ecto reference).** Line 22, `user = %User{email: email, age: age, role: role, nickname: nickname}`, builds the struct by hand and inserts it, so nothing is validated by Ecto and the hand-written checks around it each re-invent one validation. Fix: `%User{} |> User.changeset(params) |> Repo.insert()`, with `validate_required/2`, `validate_number/3` and `unique_constraint/3` in the changeset.

3. **Lookup before insert where the changeset rule names `unique_constraint/3`.** Line 24, `if Repo.get_by(User, email: email) == nil do`, is a check-then-insert race: two concurrent imports of the same address both pass the check and the second insert raises on the database index, which the `rescue` then reports as `{:error, :invalid}`. Fix: `unique_constraint(:email)` in the changeset, backed by a unique index on `users.email`, so the duplicate returns `{:error, changeset}`.

4. **Return tuples for expected failures; never `rescue _`.** Lines 10 and 42 to 43, `try do ... rescue _ -> {:error, :invalid} end`, wrap the whole body to turn `String.downcase(nil)` and `String.to_integer("abc")` into a tuple, and in doing so swallow every bug in the body too, including the constraint error from finding 3. Fix: delete the `try`; the changeset's `cast/3` returns an error for a non-integer age and `validate_required/2` for a missing email.

5. **Match every expected shape.** Line 33, `_ -> {:error, :insert_failed}`, discards the changeset that says what failed. Fix: match `{:error, changeset}` and return it. In the improved version the `case` becomes a pass-through `with`, so the error goes out unchanged.

6. **Error reasons the caller can match.** Lines 37, 40 and 43 return the same `{:error, :invalid}` for an underage user, a duplicate email and any exception, so the caller cannot tell them apart and cannot report which field was wrong. Fix: return `{:error, changeset}`; its `errors` list names the field and the reason.

7. **Assign the result of `if`; rebinding inside a block does not escape it.** Lines 15 to 17, `if age > 120 do age = 120 end`, rebind `age` inside the block, so the outer `age` keeps its value, the cap never applies, and the compiler warns about an unused variable. Fix: `validate_number(:age, greater_than_or_equal_to: 18, less_than_or_equal_to: 120)`. I chose to reject an age over 120 rather than clamp it, because a clamped value stores a number the source did not send. If clamping is what you want, use `update_change(:age, &min(&1, 120))` instead.

8. **Use `and` when the operands are booleans.** Line 21, `if is_binary(email) && age >= 18 do`, uses `&&` on two booleans. Fix: `and`. The check is also dead: `email` has already been through `String.downcase/1`, so it is a binary or the function has raised. The improved version drops the condition; `validate_required/2` and `validate_number/3` cover it.

9. **Use one atom-valued field or option instead of overlapping booleans.** Line 27, `if opts[:notify] && !opts[:silent] do`, has two options where `silent` only overrides `notify`, and `notify: true, silent: true` means nothing. Fix: keep `notify: true` alone and drop `:silent`.

10. **Give each function one return shape.** Line 31, `if opts[:return_id], do: user.id, else: {:ok, user}`, makes the return type depend on an option, so callers must know which mode they called. Fix: drop `:return_id` and always return `{:ok, user}`; a caller that wants the id reads `user.id`.

11. **Check options with `Keyword.validate!/2` and document them under `## Options`.** Line 6, `def import_user(params, opts \\ []) do`, reads `opts[:notify]`, `opts[:silent]` and `opts[:return_id]` without validating, so a misspelled option is silently ignored. Fix: `opts = Keyword.validate!(opts, notify: false)` and an `## Options` section in `@doc`.

12. **Supervise every process; use `Task.Supervisor` for fire-and-forget work (processes reference).** Line 49, `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`, starts an unsupervised, unlinked process: if delivery crashes nobody is told, and the process is invisible to Observer and shutdown. Fix: `Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(message) end)`, with `{Task.Supervisor, name: Accounts.TaskSupervisor}` added to the supervision tree.

13. **Send processes only the data they need.** The same line 49 closure captures the whole `user` struct and copies it into the new process to build one string. Fix: build the message in the caller, `message = welcome_message(user)`, and capture only `message`.

14. **Structs do not implement `Access`.** Line 53, `name = user[:name] || "there"`, raises `UndefinedFunctionError` on a `%User{}`, and `User` has no `:name` field anyway (the field is `nickname`). Because of finding 12 the crash is silent, so no welcome email has ever been sent. Fix: `user.nickname`, which is always set because the importer defaults it to the email address.

15. **Do not pipe into an anonymous function call.** Line 55, `greeting |> (fn text -> text <> " Enjoy your account." end).()`, wraps a string append in a lambda to pipe into it. Fix: one interpolated string, `"Hi #{user.nickname}, welcome! Enjoy your account."`, which also removes the `greeting` temporary and the `text` name from finding 17.

16. **Do not pipe a single step.** Line 12, `email = params["email"] |> String.downcase()`, is a one-step pipeline. Fix: `String.downcase(params["email"])`. In the improved version the downcase moves to `update_change(:email, &String.downcase/1)` on the changeset, so it only runs when an email is present.

17. **Name variables after the domain.** Line 55 names the greeting `text`. Fix: the variable goes away with finding 15.

18. **Comments explain why; documentation goes in `@moduledoc` and `@doc`.** Line 2, `# This module imports users from an external CSV/JSON source`, and line 5, `# Import a single user from the given params`, are documentation written as comments. Fix: `@moduledoc` and `@doc`. Line 7, `# Get the role from params`, and line 48, `# send the email`, restate the code. Fix: delete them. Line 11, the comment that the provider lowercases addresses before its uniqueness check, explains a reason the code cannot show, so it stays.

19. **Keep functions short and at one level of detail.** Lines 15 to 41 nest `if` inside `if` inside `case` inside `if` inside `try`, five levels deep, so the reader has to hold every branch to find where a value is returned. Fix: a `with` over one `insert_user/1` step, with the validation in the changeset and the nickname default in `put_default_nickname/1`.

## Improved code

`lib/accounts/user_importer.ex` (passes `mix format --check-formatted`; a full compile needs the project's Ecto dependency):

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  import Ecto.Changeset, only: [get_field: 2, put_change: 3, update_change: 3]

  alias Accounts.{Repo, User}

  @doc """
  Imports a single user from the string-keyed `params` of one source row.

  Returns `{:ok, user}` or `{:error, changeset}`.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, user} <- insert_user(params) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  defp insert_user(params) do
    %User{}
    |> User.changeset(params)
    # The provider lowercases addresses before its uniqueness check, so match it here
    |> update_change(:email, &String.downcase/1)
    |> put_default_nickname()
    |> Repo.insert()
  end

  defp put_default_nickname(changeset) do
    if is_nil(get_field(changeset, :nickname)) do
      put_change(changeset, :nickname, get_field(changeset, :email))
    else
      changeset
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

## Changes outside this file that the improved version depends on

The importer now relies on `Accounts.User.changeset/2` carrying the validation. If the schema does not have one yet, this is the shape it needs. The role values are placeholders; use the ones the application accepts.

```elixir
defmodule Accounts.User do
  use Ecto.Schema

  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :age, :integer
    field :role, Ecto.Enum, values: [:admin, :editor, :member]
    field :nickname, :string

    timestamps()
  end

  def changeset(user, params) do
    user
    |> cast(params, [:email, :age, :role, :nickname])
    |> validate_required([:email, :age, :role])
    |> validate_number(:age, greater_than_or_equal_to: 18, less_than_or_equal_to: 120)
    |> unique_constraint(:email)
  end
end
```

Two more one-line changes:

- A migration with `create unique_index(:users, [:email])`, so `unique_constraint(:email)` has an index to report on.
- `{Task.Supervisor, name: Accounts.TaskSupervisor}` in the application's `children` list, before any child that imports users.

Callers that passed `return_id: true` or `silent: true` need updating: read `user.id` from the `{:ok, user}` result, and omit `notify: true` instead of passing `silent: true`.
