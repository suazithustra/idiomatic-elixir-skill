# Review: `Accounts.UserImporter`

Rules come from the idiomatic-elixir skill (`SKILL.md`), with `references/ecto-phoenix.md` and `references/processes.md`.

1. The welcome email is never sent. Line 53, `name = user[:name] || "there"`, uses bracket access on a struct, which raises `UndefinedFunctionError` (Read required keys with `map.key`; structs do not implement `Access`). The error happens inside a `spawn`, so nothing reports it. Fix: read the struct field `user.nickname`, which the module already sets.

2. The role string becomes an atom. Line 8, `role = String.to_atom(params["role"])`, creates a new atom (a fixed constant name, such as `:admin`) for any input string, and atoms are never freed, so a caller can exhaust the atom table of the VM (virtual machine) (Convert external strings to atoms with explicit clauses). A missing role also raises before the `try`. Fix: match each accepted role string to its atom, and return `{:error, {:invalid_field, "role"}}` for anything else.

3. The age cap never applies. Lines 15-17, `if age > 120 do age = 120 end`, rebind `age` inside the `if`, and the new value does not leave the block (Assign the result of `if`). An age of 150 is stored as 150. Fix: `min(value, @max_age)`. This changes behavior: ages above 120 are now stored as 120.

4. A catch-all `rescue` hides every bug. Line 43, `_ -> {:error, :invalid}`, wraps the whole function, so a typo in the code and a bad input look the same (Return tuples for expected failures; raise only for bugs). The nested `if`/`case`/`try` also makes the function hard to follow (Keep functions short). Fix: parse the age with `Integer.parse/1`, check each field in a small private function, and drop the `try`.

5. The duplicate check runs before the insert, and the struct is inserted without a changeset. Lines 24-25, `Repo.get_by(User, email: email) == nil` and then `Repo.insert(user)`, can both pass for two concurrent imports of the same email (Validate input with changesets). The `_ ->` clause on line 33 also turns every insert failure into `:insert_failed`. Fix: build the row with `User.changeset/2`, let the unique index decide, and map the unique-constraint error to `:email_taken`. This assumes `User.changeset/2` calls `unique_constraint(:email)` and the table has a unique index on email. I could not see `User`, so confirm both.

6. Different failures share one reason. Lines 34, 37, 40 and 43 return `{:error, :invalid}` (or `:insert_failed`) for a missing age, an age under 18, a duplicate email and any exception (Match every expected shape). A caller cannot tell these apart. Fix: return `{:error, {:invalid_field, key}}` for bad fields and `:email_taken` for the duplicate.

7. Two booleans overlap. Line 27, `if opts[:notify] && !opts[:silent]`, makes `notify: true, silent: true` a meaningless combination (Use one atom-valued option instead of overlapping booleans). Fix: one `:notify` option with the values `:welcome` or `:none`. Callers that pass `silent:` or `notify: true` must change.

8. The return shape depends on an option. Line 31, `if opts[:return_id], do: user.id, else: {:ok, user}`, makes the function return an integer in one mode and a tuple in the other (Give each function one return shape). Fix: always return `{:ok, user}`; callers that need the id read `user.id`.

9. The welcome email runs in an unsupervised process. Line 49, `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`, has no supervisor, so a crash is lost and the process cannot be tracked (Supervise every long-lived process). The closure also captures the whole `user` struct. Fix: `Task.Supervisor.start_child/2` with a message built before the call. This assumes `Accounts.TaskSupervisor` is in the application's supervision tree.

10. The greeting is built with string concatenation and a pipe into an anonymous function. Lines 54-55, `"Hi " <> name <> ", welcome!"` and `|> (fn text -> ... end).()`, are hard to read (Do not pipe into an anonymous function). Fix: one interpolated string, `"Hi #{user.nickname}, welcome! Enjoy your account."`.

11. A single-step pipe and `&&` on booleans. Line 12, `params["email"] |> String.downcase()`, pipes one step (Do not pipe a single step). Line 21, `is_binary(email) && age >= 18`, compares booleans with `&&` (Use `and`, `or`, `not` when the operands are booleans). Fix: call the function directly and check each field in its own clause.

12. Magic numbers. Lines 15 and 21 use `120` and `18` inline (Name magic numbers with module attributes). Fix: `@max_age 120` and `@min_age 18`.

13. Comments restate the code, and the documentation is in comments. Lines 2, 5, 7 and 48 describe what the code does or document the public function in a comment (Comments explain why; documentation goes in `@moduledoc` and `@doc`). Line 11 explains a reason and stays. Fix: `@moduledoc`, `@doc` with `## Options`, and no restating comments.

14. Options are not checked. Line 6, `opts \\ []`, ignores misspelled option names silently (Group related parameters: check options with `Keyword.validate!/2`). Fix: `Keyword.validate!(opts, notify: :none)`.

Not changed: `Mailer` on line 49 is not aliased or defined in this file. The rewrite keeps it as written, so confirm the module name.

## Improved version

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external source, such as a CSV (comma-separated values)
  or JSON (JavaScript Object Notation) feed.
  """

  alias Accounts.{Repo, User}

  @max_age 120
  @min_age 18

  @doc """
  Imports a single user from string-keyed params.

  Returns `{:ok, user}` when the user is inserted. Otherwise returns one of:

    * `{:error, {:invalid_field, key}}` when a field is missing or malformed
    * `{:error, :email_taken}` when another user already has the email
    * `{:error, changeset}` when the database rejects the insert

  ## Options

    * `:notify` - `:welcome` sends a welcome email after the insert, `:none`
      sends nothing. Defaults to `:none`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: :none)

    with {:ok, attrs} <- parse_params(params),
         {:ok, user} <- insert_user(attrs) do
      maybe_send_welcome(user, opts[:notify])
      {:ok, user}
    end
  end

  defp parse_params(params) do
    with {:ok, email} <- email_field(params),
         {:ok, age} <- age_field(params),
         {:ok, role} <- role_field(params) do
      attrs = %{email: email, age: age, role: role, nickname: params["nickname"] || email}
      {:ok, attrs}
    end
  end

  # The provider lowercases addresses before its uniqueness check, so match it here
  defp email_field(%{"email" => email}) when is_binary(email) do
    {:ok, String.downcase(email)}
  end

  defp email_field(_params), do: {:error, {:invalid_field, "email"}}

  defp age_field(%{"age" => age}) when is_binary(age) do
    case Integer.parse(age) do
      {value, ""} when value >= @min_age -> {:ok, min(value, @max_age)}
      _ -> {:error, {:invalid_field, "age"}}
    end
  end

  defp age_field(_params), do: {:error, {:invalid_field, "age"}}

  # Replace these with the roles the app defines. Input is never converted with
  # String.to_atom/1, because each unknown string would create an atom that is never freed.
  defp role_field(%{"role" => "admin"}), do: {:ok, :admin}
  defp role_field(%{"role" => "editor"}), do: {:ok, :editor}
  defp role_field(%{"role" => "member"}), do: {:ok, :member}
  defp role_field(_params), do: {:error, {:invalid_field, "role"}}

  defp insert_user(attrs) do
    case Repo.insert(User.changeset(%User{}, attrs)) do
      {:ok, user} ->
        {:ok, user}

      {:error, changeset} ->
        {:error, insert_reason(changeset)}
    end
  end

  defp insert_reason(%Ecto.Changeset{errors: [email: {_message, opts}]} = changeset) do
    case Keyword.get(opts, :constraint) do
      :unique -> :email_taken
      _ -> changeset
    end
  end

  defp insert_reason(changeset), do: changeset

  defp maybe_send_welcome(user, :welcome) do
    message = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(message) end)
  end

  defp maybe_send_welcome(_user, :none), do: :ok

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

## Assumptions and behavior changes

- `User.changeset/2` exists and calls `unique_constraint(:email)`, and the database has a unique index on email. I could not see `User`.
- `Accounts.TaskSupervisor` is started in the application's supervision tree.
- The role names `admin`, `editor` and `member` are placeholders.
- The greeting uses `user.nickname`. The old code always produced "Hi there" because the bracket access raised before it could fall back.
- Callers must change: `silent:` is gone, `notify: true` becomes `notify: :welcome`, and `return_id:` is gone.
