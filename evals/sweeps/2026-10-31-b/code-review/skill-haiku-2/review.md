# Review: `code-review-input.ex`

## Findings

1. **Input turned into atoms** (`role = String.to_atom(params["role"])`, line 8). Any value in the import file creates a new atom, and atoms are never freed; the VM (virtual machine) stops at about one million, which crashes the node. Fix: declare `role` as an `Ecto.Enum` field and let `User.changeset/2` cast it, so only listed roles convert.

2. **Age cap never applies** (`if age > 120 do age = 120 end`, lines 15-17). The `age = 120` line rebinds a variable local to the `if`, so the outer `age` keeps its old value and ages over 120 are inserted. The 120 and 18 are also magic numbers. Fix: `min(age, @max_age)` with `@max_age 120`; the minimum of 18 moves into the changeset.

3. **Whole function wrapped in `try`/`rescue _`** (lines 10 and 42-43). Any bug in the function, such as a typo, becomes `{:error, :invalid}` and is never seen. `String.to_integer/1` is the only call that raises on bad input. Fix: `Integer.parse/1` returns a tuple, so no `rescue` is needed, and real bugs raise.

4. **`&&` on booleans** (`is_binary(email) && age >= 18`, line 21; `opts[:notify] && !opts[:silent]`, line 27). `and` and `not` check that their operands are booleans; `&&` and `!` accept any value. Fix: `and` and `not`, with the options validated first (finding 9).

5. **Lookup before insert** (`if Repo.get_by(User, email: email) == nil`, line 24). Two imports of the same email can both pass this check, and the database can still reject the second insert. Fix: `unique_constraint(:email)` in the changeset, so the insert returns `{:error, changeset}`.

6. **Struct inserted without a changeset** (`user = %User{email: email, ...}` and `Repo.insert(user)`, lines 22 and 25). Ecto inserts the struct as given, so no validation runs and the age minimum is checked by hand. Fix: `%User{} |> User.changeset(attrs) |> Repo.insert()`.

7. **Catch-all clause and nested branches** (`_ -> {:error, :insert_failed}`, line 33; the `if`/`case` nesting in lines 15-41). The `_` clause turns every other return value, including future ones, into the same error. Fix: a `with` chain where each step returns `{:ok, _}` or `{:error, _}` and the error passes through unchanged.

8. **Option changes the return shape** (`if opts[:return_id], do: user.id, else: {:ok, user}`, line 31). A caller gets an integer or a tuple depending on an option. Fix: remove `:return_id`; the function always returns `{:ok, user}`, and a caller that needs the ID reads `user.id`. This is a behavior change for any caller that passes `return_id: true`.

9. **Options not checked** (`def import_user(params, opts \\ [])`, line 6). A misspelled option is silently ignored, and the options are not documented. Fix: `Keyword.validate!(opts, notify: false, silent: false)`, with the options listed under `## Options` in `@doc`.

10. **String keys read one at a time with nil checks** (`params["role"]`, `params["email"]`, `params["age"]`, lines 8, 12, 13). A missing key only shows up later as a confusing error. Fix: match the required keys in the function head, and let a second clause return `{:error, :invalid_payload}` for input without them.

11. **Bare `spawn` that captures the whole user** (`spawn(fn -> Mailer.deliver(welcome_email(user)) end)`, line 49). A bare process has no supervisor, so a crash is lost. The closure also copies the whole `user` into the new process. Fix: `Task.Supervisor.start_child/2`, with only the finished message string captured. This assumes `Accounts.TaskSupervisor` is started in the application's supervision tree.

12. **Dot-free access on a struct** (`name = user[:name] || "there"`, line 53). Structs do not implement the `Access` behavior, so `user[:name]` raises `UndefinedFunctionError`. The `User` in this code also has no `name` field; `nickname` always holds a value because it defaults to the email. Fix: `user.nickname`.

13. **Pipe into an anonymous function** (`greeting |> (fn text -> text <> " Enjoy your account." end).()`, line 55). It is hard to read and not allowed by the style rules. Fix: one string interpolation.

14. **Single-step pipe** (`email = params["email"] |> String.downcase()`, line 12). A pipe with one step adds nothing. Fix: `String.downcase(email)`.

15. **Documentation as comments** (`# This module imports users...`, line 2; `# Import a single user...`, line 5; `# Get the role from params`, line 7; `# send the email`, line 48). Module and function docs belong in `@moduledoc` and `@doc`, and comments that restate the code should go. The comment on line 11 explains a reason the code cannot show, so it stays.

## Improved code

Assumes `User.changeset/2` (in `Accounts.User`) casts `email`, `age`, `role`, and `nickname`, declares `role` as `Ecto.Enum`, validates `age` with `greater_than_or_equal_to: 18`, and calls `unique_constraint(:email)`. The database needs a unique index on `email`.

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.{Repo, User}

  @max_age 120

  @doc """
  Imports one user from string-keyed params.

  Returns `{:ok, user}` on success, `{:error, changeset}` when the user fails
  validation or the email is already taken, `{:error, {:invalid_field, "age"}}`
  when `age` is not an integer string, and `{:error, :invalid_payload}` when a
  required key is missing.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
    * `:silent` - suppresses the welcome email even when `:notify` is `true`.
      Defaults to `false`.
  """
  def import_user(params, opts \\ [])

  def import_user(%{"email" => email, "age" => age, "role" => role} = params, opts) do
    opts = Keyword.validate!(opts, notify: false, silent: false)

    with {:ok, age} <- parse_age(age),
         {:ok, user} <- insert_user(email, age, role, params["nickname"]) do
      if opts[:notify] and not opts[:silent], do: send_welcome(user)
      {:ok, user}
    end
  end

  def import_user(_params, _opts), do: {:error, :invalid_payload}

  defp parse_age(text) do
    case Integer.parse(text) do
      {age, ""} -> {:ok, min(age, @max_age)}
      {_age, _rest} -> {:error, {:invalid_field, "age"}}
      :error -> {:error, {:invalid_field, "age"}}
    end
  end

  defp insert_user(email, age, role, nickname) do
    # The provider lowercases addresses before its uniqueness check, so match it here
    email = String.downcase(email)

    attrs = %{
      "email" => email,
      "age" => age,
      "role" => role,
      "nickname" => nickname || email
    }

    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
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
