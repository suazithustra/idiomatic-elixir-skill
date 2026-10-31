# Review: `Accounts.UserImporter`

The import function turns untrusted input into atoms, hides every failure behind one generic error, and can silently skip the age cap and the welcome email. The fixes below replace the atom conversion, remove the catch-all `try`, and split the function into small steps that each return `{:ok, value}` or `{:error, reason}`.

## Findings

1. Atoms are created from input. Line 8, `role = String.to_atom(params["role"])`, turns any string from the file into an atom. Atoms are never freed, and the virtual machine (VM) stops at about 1,048,576 of them, so a large or hostile file can crash the node. A missing role (`nil`) also raises on line 8, which sits outside the `try`, so the rescue never sees it. Rule: Convert external strings to atoms with explicit clauses. Fix: `parse_role/1` lists the accepted values and returns an error for anything else.

2. A `try` wraps the whole function. Lines 10 and 42-43, `rescue _ -> {:error, :invalid}`, turn every failure into the same `:invalid`, including a database outage or a bug in this module. Line 13, `String.to_integer(params["age"])`, raises on bad input, where `Integer.parse/1` returns a tuple. Rule: Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs. Fix: `Integer.parse/1` in `parse_age/1`, and no `try`.

3. Required keys are read with `params["key"]`. Lines 12, 13 and 19 read keys that may be missing. A missing email becomes `nil`, `String.downcase/1` raises, and the rescue reports `:invalid` with no reason. Rule: Match the required keys of string-keyed input in a function head, with a clause for the rest. Fix: `read_attrs/1` matches `"email"`, `"age"` and `"role"` in its head, and `read_attrs(_params)` returns `{:error, :invalid_params}`.

4. The age cap never applies. Lines 15-17 assign `age = 120` inside an `if`. A variable bound inside an `if` is local to that block, so the outer `age` stays 150 and the cap is skipped. Rule: Assign the result of `if`, `case`, and `Enum` calls. Fix: `min(age, @max_age)` in `parse_age/1`.

5. The `&&` operator is used on booleans. Lines 21 and 27, `is_binary(email) && age >= 18`, accept any value and do not check intent. Rule: Use `and`, `or`, `not` when the operands are booleans. Fix: `and`, or a guard in the function head.

6. Two options overlap. Line 27, `opts[:notify] && !opts[:silent]`, uses two booleans where one value would do, and a typo in an option name is ignored silently. Rule: Use one atom-valued field or option instead of overlapping booleans. Fix: keep `notify` and remove `silent`. `Keyword.validate!/2` rejects unknown options, so a caller that still passes `silent:` gets an error. This is a change for callers.

7. The code checks for a duplicate and then inserts a raw struct. Lines 22-25 call `Repo.get_by/2` and then `Repo.insert(user)` on a `%User{}` struct. Two concurrent imports of the same email can both pass the check, and the second insert then breaks the database's unique index. Because the struct skips validation, that error raises, and the rescue turns it into `:invalid`. Rule: Cast and validate external input with `Ecto.Changeset`, and declare constraints with `unique_constraint/3`. Fix: `insert_user/1` builds a changeset, and a duplicate comes back as `{:error, changeset}`.

8. A catch-all clause hides insert errors. Line 33, `_ -> {:error, :insert_failed}`, turns every other result into one reason. Rule: Match every expected shape and let unexpected ones crash. Fix: `Repo.insert/1` returns `{:ok, user}` or `{:error, changeset}`, and `with` passes both through unchanged.

9. An option changes the return shape. Line 31, `if opts[:return_id], do: user.id, else: {:ok, user}`, returns an integer in one mode and a tuple in the other, so a caller that matches `{:ok, user}` crashes. Rule: Give each function one return shape. Fix: remove `:return_id`. Callers that need the id read `user.id` from `{:ok, user}`. This is a change for callers.

10. A welcome email is started with a bare `spawn`. Line 49, `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`, runs outside any supervisor, so a crash is lost and nothing restarts it. Rule: Supervise every long-lived process. Fix: `Task.Supervisor.start_child/2` under `Accounts.TaskSupervisor`, which must be in the application's supervision tree.

11. A struct is read with `Access`. Line 53, `user[:name]`, raises `UndefinedFunctionError`, because structs do not implement the `Access` behaviour (the `[]` lookup syntax). The raise happens inside the spawned process, so the email is never sent and nothing reports it. Rule: Read struct fields with `user.name` or a pattern, and keep `map[:key]` for optional keys. Fix: `Map.get(user, :name) || "there"`, which keeps the original fallback for a missing name.

12. The code pipes into an anonymous function. Line 55, `greeting |> (fn text -> text <> " Enjoy your account." end).()`, is hard to read. Rule: Do not pipe into an anonymous function call. Fix: one string with interpolation. Line 12, `params["email"] |> String.downcase()`, is a one-step pipe, and the rule against those applies there too.

13. Structure and comments. The function nests four levels deep. Comments on lines 2, 5, 7 and 48 restate the code, and the module and public function have no `@moduledoc` or `@doc`. Rule: Keep functions short and at one level of detail; Comments explain why. Fix: a `with` chain of small private functions, `@moduledoc` and `@doc` in place of the comments. The provider comment on line 11 explains a reason, so it stays.

## Assumptions in the improved code

- `User.changeset/2` exists and calls `unique_constraint(:email)`. Without that, the duplicate-email check does not run and the insert raises.
- `Accounts.TaskSupervisor` is started in the supervision tree.
- The roles `admin`, `editor` and `member` are placeholders. Replace them with the application's real roles.
- The `User` struct may have no `name` field. `Map.get/2` handles that.
- `Mailer` and `Repo` exist as in the original.
- The improved code was not compiled or run. The shell check for Elixir was not approved in this session.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV (comma-separated values) or JSON (JavaScript Object Notation) source.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from the given params.

  Returns `{:ok, user}` or `{:error, reason}`.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, attrs} <- read_attrs(params),
         {:ok, user} <- insert_user(attrs) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  defp read_attrs(%{"email" => email, "age" => age_text, "role" => role_text} = params)
       when is_binary(email) and is_binary(age_text) do
    with {:ok, age} <- parse_age(age_text),
         {:ok, role} <- parse_role(role_text) do
      # The provider lowercases addresses before its uniqueness check, so match it here
      email = String.downcase(email)
      nickname = params["nickname"] || email
      {:ok, %{email: email, age: age, role: role, nickname: nickname}}
    end
  end

  defp read_attrs(_params), do: {:error, :invalid_params}

  defp parse_age(text) do
    case Integer.parse(text) do
      {age, ""} when age >= @min_age -> {:ok, min(age, @max_age)}
      {_age, ""} -> {:error, :underage}
      _ -> {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("editor"), do: {:ok, :editor}
  defp parse_role("member"), do: {:ok, :member}
  defp parse_role(_other), do: {:error, {:invalid_field, "role"}}

  defp insert_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp send_welcome(user) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user) do
    name = Map.get(user, :name) || "there"
    "Hi #{name}, welcome! Enjoy your account."
  end
end
```
