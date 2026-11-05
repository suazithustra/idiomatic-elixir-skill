# Review: `Accounts.UserImporter`

The importer builds a user record by hand and checks its fields by hand, inside one `try` that turns every error into `{:error, :invalid}`. Most findings below come from that one choice. The fix is to move the field rules into an Ecto changeset (a validated description of the changes to a database record), so the importer only calls `Repo.insert/1` and passes the result back.

Line numbers refer to `code-review-input.ex`.

## Findings

1. The welcome email is never sent. Line 53, `name = user[:name] || "there"`, raises because structs do not support `[]` access (rule: read required keys with `map.key`, and structs with `user.name` or a pattern). The raise happens inside a `spawn` (see finding 14), so nothing reports it. The record has a `nickname` field that the import always sets, so the fix reads `user.nickname` and builds the text in the calling process.

2. The age cap never applies. Line 16, `age = 120`, sits inside the `if` on line 15, and a variable rebound inside an `if` does not leave it (rule: assign the result of `if`). A user with age 150 is stored as 150. The fix is `update_change(:age, &min(&1, @max_age))` in the changeset.

3. The whole function is wrapped in `try` with `rescue _ -> {:error, :invalid}` on lines 42-43 (rule: rescue only a specific exception around third-party code, never `rescue _` around a whole function). Any bug, such as a typo in a field name, becomes the same error as bad input and disappears. Removing the `try` lets real bugs raise where they happen.

4. `String.to_integer(params["age"])` on line 13 raises on text such as `"abc"` (rule: use the non-raising version and return an error). The changeset's `cast/3` reports a non-integer age as an error on `:age`.

5. `role = String.to_atom(params["role"])` on line 8 creates an atom from input, and atoms are never garbage-collected (rule: convert external strings to atoms with explicit clauses). A missing role raises `ArgumentError` outside the `try`. For a fixed set of values, the rule names `Ecto.Enum`, which casts `"admin"` to `:admin` and rejects anything else. The list `[:admin, :editor, :member]` in the companion schema is a placeholder for the application's real roles.

6. Line 22, `user = %User{email: email, age: age, role: role, nickname: nickname}`, followed by `Repo.insert(user)` on line 25, inserts a struct with no validation (rule: validate external input with a changeset). The fix is `%User{} |> User.import_changeset(params) |> Repo.insert()`.

7. Line 24, `if Repo.get_by(User, email: email) == nil do`, checks for a duplicate before the insert (rule: declare the uniqueness constraint with `unique_constraint/3`). Two imports running at the same time can both pass the check. The fix is `unique_constraint(:email)` in the changeset. The database must have a unique index on the email column; Ecto's default name for it is `users_email_index`.

8. Lines 33-34, `_ -> {:error, :insert_failed}`, catch every other return value of `Repo.insert/1` and drop its reason (rule: match every expected shape, and pass the reason on). `Repo.insert/1` already returns `{:error, changeset}`, so the fix passes that value through unchanged.

9. Lines 37, 40 and 43 all return `{:error, :invalid}`. A duplicate email, an age under 18, and a missing or malformed field look the same to the caller (rule: different failures need different reasons). With the changeset, each failure is an error on a named field, such as `:email` or `:age`.

10. Line 31, `if opts[:return_id], do: user.id, else: {:ok, user}`, makes an option change what the function returns: an integer in one case and a tuple in the other (rule: give each function one return shape). The fix removes the option; the function returns `{:ok, user}` and callers read `user.id`. Callers that passed `return_id: true` must change.

11. Line 27, `if opts[:notify] && !opts[:silent] do`, uses two booleans where `silent` only cancels `notify` (rule: use one atom-valued option instead of overlapping booleans). The options are also never checked, so a misspelled key is ignored. The fix is `notify: :welcome | :none`, checked with `Keyword.validate!(opts, notify: :none)`. Callers that pass `silent:` will now get an `ArgumentError`.

12. Line 21, `if is_binary(email) && age >= 18 do`, uses `&&` on booleans (rule: use `and` when the operands are booleans). The `is_binary/1` check also cannot fail here, because `String.downcase/1` on line 12 raises first for a non-string. The changeset handles both checks.

13. Line 12, `email = params["email"] |> String.downcase()`, pipes a single step (rule: do not pipe a single step). The fix is `update_change(:email, &String.downcase/1)` in the changeset, which runs only when an email was given.

14. Line 49, `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`, starts a process outside any supervisor (rule: supervise every long-lived process). If it crashes, nothing records it, and the closure copies the whole `user` struct and builds the email inside the new process. The fix builds the email in the caller and starts the send with `Task.Supervisor.start_child/2`. The application must start `Accounts.TaskSupervisor` in its supervision tree.

15. Line 55, `greeting |> (fn text -> text <> " Enjoy your account." end).()`, pipes into an anonymous function call (rule: do not pipe into an anonymous function). Lines 53-54 also build the same text in three steps. One interpolated string replaces all of it.

16. The comments restate the code: line 2 (`# This module imports users...`), line 7 (`# Get the role from params`), and line 48 (`# send the email`). Line 5 documents a public function with a comment instead of `@doc` (rule: document with `@doc` and `@moduledoc`, and keep comments for reasons). The module has no `@moduledoc`, and the `alias` comes before any module attribute. The one comment that explains a reason (line 11, about the provider lowercasing addresses) moves to the changeset, next to the line it explains.

17. `import_user/2` nests `if`, `case` and `if` four levels deep, lines 15-41 (rule: keep functions short and at one level of detail; move an inner `case` or `if` into a named private function). The fix is a `with` with one step, which passes the changeset error through, and small private functions for the send step.

## Improved code

`user_importer.ex`:

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.

  Params are string-keyed maps. The field rules live in
  `Accounts.User.import_changeset/2`.
  """

  alias Accounts.{Repo, User}

  @doc """
  Imports one user from string-keyed `params`.

  Returns `{:ok, user}` or `{:error, changeset}`. The changeset's errors name
  the failing field, such as `:email` for an address already in use or `:age`
  for a user under 18.

  ## Options

    * `:notify` - `:welcome` sends a welcome email after the insert.
      Defaults to `:none`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: :none)

    with {:ok, user} <- insert_user(params) do
      maybe_send_welcome(user, opts[:notify])
      {:ok, user}
    end
  end

  defp insert_user(params) do
    %User{}
    |> User.import_changeset(params)
    |> Repo.insert()
  end

  defp maybe_send_welcome(user, :welcome), do: send_welcome(user)
  defp maybe_send_welcome(_user, :none), do: :ok

  defp send_welcome(user) do
    email = welcome_email(user)

    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn ->
      Mailer.deliver(email)
    end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

`user.ex` (companion; this module is not in the input, so the schema fields are the ones the original `%User{}` literal used, and the role list is a placeholder):

```elixir
defmodule Accounts.User do
  use Ecto.Schema

  import Ecto.Changeset

  @min_age 18
  @max_age 120

  schema "users" do
    field :email, :string
    field :age, :integer
    field :role, Ecto.Enum, values: [:admin, :editor, :member]
    field :nickname, :string

    timestamps()
  end

  @doc """
  Casts and validates a user built from imported params.

  Lowercases the email, caps the age at #{@max_age}, rejects ages under
  #{@min_age}, and turns a duplicate email into an error on `:email`.
  """
  def import_changeset(user, params) do
    user
    |> cast(params, [:email, :age, :role, :nickname])
    |> validate_required([:email, :age, :role])
    # The provider lowercases addresses before its uniqueness check, so match it here.
    |> update_change(:email, &String.downcase/1)
    |> update_change(:age, &min(&1, @max_age))
    |> validate_number(:age, greater_than_or_equal_to: @min_age)
    |> put_nickname()
    |> unique_constraint(:email)
  end

  defp put_nickname(changeset) do
    nickname = get_field(changeset, :nickname) || get_field(changeset, :email)
    put_change(changeset, :nickname, nickname)
  end
end
```

## Notes

- Changed behavior: the age cap still clamps to 120, as the original code intended. The original never clamped (finding 2). If you want ages over 120 rejected instead, replace the `update_change(:age, ...)` line with `validate_number(:age, less_than_or_equal_to: @max_age)`.
- Callers must change for findings 10 and 11: `return_id` is gone, and `silent` raises an `ArgumentError`.
- Needed elsewhere in the app: a unique index on `users.email`, a `Accounts.TaskSupervisor` in the supervision tree, and the real list of roles in the schema.
- Not checked: I did not compile these files, because `Accounts.User`, `Repo` and `Mailer` are not in the project here. Both files parse, and `mix format --check-formatted` passes for `user_importer.ex`. The default formatter wants parentheses around the `field` calls in `user.ex`; a project whose `.formatter.exs` imports Ecto's formatter rules (`import_deps: [:ecto]`) keeps them as written.
