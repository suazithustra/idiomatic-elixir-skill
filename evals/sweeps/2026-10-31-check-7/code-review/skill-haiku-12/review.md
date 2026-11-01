# Review: `Accounts.UserImporter`

The module turns an unchecked import row into a user. It crashes or quietly misbehaves on bad input, and its welcome email never sends. The fix moves validation into an Ecto changeset (the Ecto validation layer), so bad rows come back as `{:error, changeset}`.

## Findings

1. **Atoms created from input (line 8).** `String.to_atom(params["role"])` creates an atom from any string in the file. Atoms are never freed, so a crafted file can exhaust the atom table and crash the node. A missing role also raises. Rule: SKILL.md, "Convert external strings to atoms with explicit clauses". Fix: declare `role` as an `Ecto.Enum` field in `User` and let `cast/3` map the strings.

2. **Catch-all `rescue` around the whole function (lines 10 and 42-43).** `rescue _ -> {:error, :invalid}` hides every bug, including typos and database failures, behind one reason. Rule: SKILL.md, "Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs". Fix: remove the `try`. Validation returns errors without raising.

3. **Raising parse of user input (line 13).** `String.to_integer(params["age"])` raises on `"abc"` or `nil`, and the `rescue` above turns that into a generic error. Rule: SKILL.md, "Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs", which asks for the non-raising version (`Integer.parse/1`). Fix: `cast/3` parses the string and reports `"is invalid"` on the `age` field.

4. **Age clamp never runs (lines 15-17).** The `age = 120` inside `if` is local to the `if` block, so `age` keeps its original value. The clamp does nothing. Rule: SKILL.md, "Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it". Fix: the changeset rejects ages above 120 with `validate_number/3`. This is a behavior change: the original intent was to clamp, and the owner should confirm that rejecting is what they want. Clamping would be `min(age, 120)` on the parsed value.

5. **Magic numbers (lines 21 and 15).** `120` and `18` appear inline. Rule: SKILL.md, "Name magic numbers with module attributes: `@session_ttl :timer.hours(24)`." Fix: `@min_age` and `@max_age` in `User`, where the age rules now live.

6. **Lookup before insert (lines 24 and 25).** `Repo.get_by/2` followed by `Repo.insert/1` is a race: two imports of the same email can both pass the lookup, and one insert then fails or duplicates. Rule: SKILL.md, "Validate input with changesets" in `references/ecto-phoenix.md`, which asks for `unique_constraint/3` in the changeset. Fix: `unique_constraint(:email)` turns the database error into `{:error, changeset}`. This needs a unique index on `users.email`.

7. **Struct inserted without a changeset (line 22 and 25).** `%User{email: ..., age: ...}` goes straight to `Repo.insert/1`, so nothing is validated. Rule: `references/ecto-phoenix.md`, "Validate input with changesets", which says to use `%User{} |> User.changeset(params) |> Repo.insert()`. Fix: that pipeline, with the checks in `User.changeset/2`.

8. **Catch-all error clause (line 33).** `_ -> {:error, :insert_failed}` returns one reason for every failure, so callers cannot tell a duplicate email from a bad row. Rule: SKILL.md, "Match every expected shape and let unexpected ones crash". Fix: the changeset carries the field errors, and `Repo.insert/1` is matched by `with`, so no catch-all is needed.

9. **One function, two return shapes (line 31).** `if opts[:return_id], do: user.id, else: {:ok, user}` returns a bare integer in one mode and a tuple in the other. Rule: SKILL.md, "Give each function one return shape". Fix: `import_user/2` always returns `{:ok, user}`, and `import_user_id/2` returns `{:ok, id}`.

10. **Overlapping boolean options (line 27).** `opts[:notify] && !opts[:silent]` combines two flags where `notify: true, silent: true` makes no sense. Rule: SKILL.md, "Use one atom-valued field or option instead of overlapping booleans". Fix: drop `:silent`, since `:notify` already defaults to `false`. Callers that pass `silent:` will now get an `ArgumentError` from `Keyword.validate!/2`, which is intended.

11. **Unsupervised process that captures the whole user (line 49).** `spawn(fn -> ... end)` is not supervised, so a crash is not logged or restarted, and the closure copies the whole `user` into the new process. Rule: `references/processes.md`, "Supervise every long-lived process". Fix: `Task.Supervisor.start_child/2` under an `Accounts.TaskSupervisor` in the application's supervision tree, and the closure captures only the built email.

12. **The welcome email always crashes (line 53).** `user[:name]` raises `UndefinedFunctionError` on a struct, because structs do not implement `Access`, and `User` has no `name` field anyway. The crash happens inside the unsupervised process, so nothing reports it. Rule: SKILL.md, "Read required keys with `map.key` or a pattern; keep `map[:key]` for optional keys", which notes that structs do not implement `Access`. Fix: greet with `user.nickname`, which the changeset always sets. This changes the greeting text from "there" to the nickname.

13. **Pipe into an anonymous function (line 55).** `greeting |> (fn text -> ... end).()` is hard to read, and the greeting is a single string. Rule: SKILL.md, "Write pipelines that start with a value and read top to bottom", which says not to pipe into an anonymous function. Fix: one interpolated string.

14. **Single-step pipe (line 12).** `params["email"] |> String.downcase()` is one call written as a pipe, and `String.downcase/1` raises on `nil`. Rule: SKILL.md, "Write pipelines that start with a value and read top to bottom", which says not to pipe a single step. Fix: the downcase moves to `update_change/3` in the changeset, which skips a missing value.

15. **Comments that restate the code and a missing `@moduledoc`/`@doc` (lines 2, 5, 7, 19, 48, 52).** Most comments repeat what the next line says, and the module and function docs are comments, so `h/1` shows nothing. Rule: SKILL.md, "Comments explain why; documentation goes in `@moduledoc` and `@doc`". Fix: `@moduledoc`, `@doc` with options, and only the comment that explains a reason is kept, now in `User.changeset/2`.

16. **Options not validated, and a nested function doing four jobs (lines 6-45).** `opts` is read with `opts[:key]` and never checked, so a typo such as `notfy:` is silently ignored. The function also nests `if`, `case` and `try`, which makes it hard to follow. Rule: SKILL.md, "Group related parameters" (check optional settings with `Keyword.validate!/2`) and "Keep functions short and at one level of detail". Fix: `Keyword.validate!/2` checks the options, and the public function is a `with` over short steps.

## Assumptions

The rewrite assumes a `User.changeset/2` that casts `email`, `age`, `role` and `nickname`, declares `role` as `Ecto.Enum` with the values your schema already lists, sets `nickname` to the email when it is missing, and has a unique index on `users.email`. It also assumes an `Accounts.TaskSupervisor` in the application's supervision tree. Those files are not in the input, so the code below does not compile against this module alone.

## Improved code

`lib/accounts/user_importer.ex`:

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV (comma-separated values) or JSON (JavaScript Object Notation) source.
  """

  alias Accounts.{Repo, User}

  @doc """
  Imports a single user from string-keyed params.

  Returns `{:ok, user}`, or `{:error, changeset}` when the params are invalid or the email is already taken.

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

  @doc """
  Imports a single user and returns `{:ok, id}`.

  Takes the same options as `import_user/2`.
  """
  def import_user_id(params, opts \\ []) do
    with {:ok, user} <- import_user(params, opts), do: {:ok, user.id}
  end

  defp insert_user(params) do
    %User{}
    |> User.changeset(params)
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

`lib/accounts/user.ex` (the parts this module depends on):

```elixir
@min_age 18
@max_age 120

def changeset(user, attrs) do
  user
  |> cast(attrs, [:email, :age, :role, :nickname])
  # The provider lowercases addresses before its uniqueness check, so match it here
  |> update_change(:email, &String.downcase/1)
  |> default_nickname()
  |> validate_required([:email, :age, :role])
  |> validate_number(:age, greater_than_or_equal_to: @min_age, less_than_or_equal_to: @max_age)
  |> unique_constraint(:email)
end

defp default_nickname(changeset) do
  case get_field(changeset, :nickname) do
    nil -> put_change(changeset, :nickname, get_field(changeset, :email))
    _nickname -> changeset
  end
end
```
