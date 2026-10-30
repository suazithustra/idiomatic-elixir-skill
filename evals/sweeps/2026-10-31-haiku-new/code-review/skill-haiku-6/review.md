# Review: `Accounts.UserImporter`

The welcome email never sends, and the age cap never applies. A `rescue` clause turns every failure into `{:error, :invalid}`, including a failure that happens after the user row is already saved, so the bug is hidden from the caller. The fix removes the `try` block, validates each field where it enters, and uses a changeset (Ecto's validation and database-write helper) for the insert.

## Findings

Rules are from `SKILL.md` unless marked `references/`.

### 1. The welcome email call crashes, and the crash is hidden

Line 53, `name = user[:name] || "there"`, reads a key from a struct. Structs do not implement `Access`, so this raises `UndefinedFunctionError`. The `rescue _ ->` on line 43 catches it and returns `{:error, :invalid}` after the row is already inserted. Rule: "Read required keys with `map.key` or a pattern; keep `map[:key]` for optional keys". Fix: use `user.nickname`, which the importer always sets.

### 2. The age cap never takes effect

Lines 15-17, `if age > 120 do age = 120 end`, rebind `age` inside the `if`, and the new value does not leave the block. Rule: "Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it". Fix: `age: min(age, @max_age)`.

### 3. A catch-all `rescue` hides bugs

Lines 10 and 42-44 wrap the whole function in `try` and `rescue _ ->`. Any bug inside the function becomes `{:error, :invalid}`. Rule: "Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs", which says to rescue a specific exception, never `rescue _ ->` around a whole function. Fix: remove the `try`; use the non-raising calls in findings 4 and 5.

### 4. `String.to_atom/1` on input lets callers fill the atom table

Line 8, `role = String.to_atom(params["role"])`, creates an atom from any string a caller sends, and crashes when `"role"` is missing (`String.to_atom(nil)`). Rule: "Convert external strings to atoms with explicit clauses". Fix: `parse_role/1` with one clause per allowed role. The three role names used here (`admin`, `editor`, `member`) are guesses; replace them with the app's real roles.

### 5. `String.to_integer/1` raises on bad input

Line 13, `age = String.to_integer(params["age"])`, raises on any non-number. Rule: "Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs", which says to call the non-raising version, here `Integer.parse/1`. Fix: `parse_integer/2`.

### 6. The uniqueness check runs before the insert

Lines 24-38, `Repo.get_by(User, email: email) == nil` and then `Repo.insert(user)`, check for a duplicate and then write. Two requests can both pass the check, and the second write then fails. Rule: "Validate input with changesets" (`references/ecto-phoenix.md`), which names `unique_constraint/3` for this case, so a duplicate comes back as `{:error, changeset}`. Fix: declare `unique_constraint(:email)` in `User.changeset/2` and delete the lookup. The database also needs a unique index on `email`.

### 7. A raw struct goes to the database with no validation

Lines 22 and 25, `%User{email: email, age: age, role: role, nickname: nickname}` passed to `Repo.insert/1`, write the struct without any checks. Rule: "Validate input with changesets" (`references/ecto-phoenix.md`), which says to build `%User{} |> User.changeset(params) |> Repo.insert()`. Fix: the `insert_user/1` function below.

### 8. The error clause catches everything

Line 33, `_ -> {:error, :insert_failed}`, turns every other return value, including a changeset error, into one error. Rule: "Match every expected shape and let unexpected ones crash". Fix: the `with` in `import_user/2` returns `{:error, changeset}` unchanged.

### 9. Two overlapping booleans control the welcome email

Line 27, `if opts[:notify] && !opts[:silent]`, means `notify: true, silent: true` does nothing, which is a combination the caller can pass without any warning. Rule: "Use one atom-valued field or option instead of overlapping booleans". Fix: `notify: :welcome | :none`, checked with `Keyword.validate!/2`.

### 10. `return_id` changes the return shape

Line 31, `if opts[:return_id], do: user.id, else: {:ok, user}`, returns a bare integer on one path and a tuple on the other. Rule: "Give each function one return shape". Fix: remove the option. Callers that passed `return_id: true` now read `user.id` from `{:ok, user}`. No caller is in the input, so any such caller must be updated.

### 11. Bare `spawn/1` for a background send

Line 49, `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`, starts a process outside any supervisor, so a crash is not reported and the process does not appear in monitoring tools. Rule: "Supervise every long-lived process" (`references/processes.md`), which names `Task.Supervisor.start_child/2` for fire-and-forget work. The closure also captured the whole `user`; the fix captures only the email text. Fix: `Task.Supervisor.start_child(Accounts.TaskSupervisor, ...)`. The app must start `{Task.Supervisor, name: Accounts.TaskSupervisor}`.

### 12. Every failure returns the same error

Lines 37, 40, and 43 all return `{:error, :invalid}`, so a caller cannot tell a missing email from a bad age. Rule: "Parse external data into structs where it enters the system", which says that when the caller needs to know which field failed, each field is checked in a small function and returns `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}`. Fix: `string_field/2`, `integer_field/2`, `check_age/1`, and `role_field/1`.

### 13. `&&` on a value that is already a string

Line 21, `if is_binary(email) && age >= 18`, uses `&&` where the rule says `and`, and the `is_binary` check is redundant because `String.downcase/1` on line 12 would already have raised on a non-string. Rule: "Use `and`, `or`, `not` when the operands are booleans". Fix: the field checks in finding 12 replace the line.

### 14. A pipeline with one step

Line 12, `email = params["email"] |> String.downcase()`. Rule: "Do not pipe a single step: write `String.trim(name)`, not `name |> String.trim()`." Fix: `String.downcase(email)`.

### 15. Pipe into an anonymous function

Line 55, `greeting |> (fn text -> text <> " Enjoy your account." end).()`, is a pipe into a `fn` call. Rule: "Do not pipe into an anonymous function call". Fix: one interpolated string.

### 16. One long public function at five levels of nesting

Lines 6-45 nest `if`, `if`, `if`, `case`, and `try` in one function. Rule: "Keep functions short and at one level of detail". Fix: `import_user/2` becomes a three-step `with`, and each step is a private function below it.

### 17. Comments restate the code

Lines 2, 5, 7, and 48 (`# This module imports...`, `# Import a single user...`, `# Get the role from params`, `# send the email`) describe what the next line does. Rule: "Comments explain why; documentation goes in `@moduledoc` and `@doc`". Fix: `@moduledoc` and `@doc` carry the first two, and the other two are deleted. The comment on line 11 explains a reason the code cannot show, so it stays.

## Assumptions and behavior changes

- `Accounts.User` needs a `changeset/2`. The input does not include the module, so the version below is a sketch:

  ```elixir
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :age, :role, :nickname])
    |> validate_required([:email, :age, :role])
    |> unique_constraint(:email)
  end
  ```

- `Accounts.TaskSupervisor` must be in the application's supervision tree.
- Welcome emails now send. Before, they never did (finding 1).
- The `:return_id` option is gone (finding 10).
- The role names are placeholders (finding 4).
- Errors now name the field (finding 12).

## Improved version

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV (comma-separated values) or JSON (JavaScript Object Notation) source.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports one user from string-keyed `params`.

  ## Options

    * `:notify` - `:welcome` sends a welcome email after the insert,
      `:none` sends nothing. Defaults to `:none`.

  Returns `{:ok, user}`, or `{:error, reason}` where `reason` is
  `{:missing_field, key}`, `{:invalid_field, key}`, or an `Ecto.Changeset`
  when the database rejects the row.
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
    # The provider lowercases addresses before its uniqueness check, so match it here
    with {:ok, email} <- string_field(params, "email"),
         {:ok, age} <- integer_field(params, "age"),
         :ok <- check_age(age),
         {:ok, role} <- role_field(params) do
      attrs = %{
        email: String.downcase(email),
        age: min(age, @max_age),
        role: role,
        nickname: params["nickname"] || email
      }

      {:ok, attrs}
    end
  end

  defp string_field(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp integer_field(params, key) do
    with {:ok, text} <- string_field(params, key) do
      parse_integer(text, key)
    end
  end

  defp parse_integer(text, key) do
    case Integer.parse(text) do
      {integer, ""} -> {:ok, integer}
      {_integer, _rest} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:invalid_field, key}}
    end
  end

  defp check_age(age) when age >= @min_age, do: :ok
  defp check_age(_age), do: {:error, {:invalid_field, "age"}}

  defp role_field(params) do
    with {:ok, text} <- string_field(params, "role") do
      parse_role(text)
    end
  end

  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("editor"), do: {:ok, :editor}
  defp parse_role("member"), do: {:ok, :member}
  defp parse_role(_text), do: {:error, {:invalid_field, "role"}}

  defp insert_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp maybe_send_welcome(user, :welcome) do
    body = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(body) end)
  end

  defp maybe_send_welcome(_user, :none), do: :ok

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```
