# Review: `Accounts.UserImporter`

The import never applies the age cap, because the cap is set inside an `if` and the value does not leave it. Several other problems follow from the same code shape: a `try` that hides every error, a check-then-insert that can race, and an atom created from input. The fixes below are in the improved version at the end.

## Findings

**1. Age cap never applies (correctness).** Rule: "Assign the result of `if`, `case`, and `Enum` calls." The line `age = 120` sits inside `if age > 120 do ... end`, so the outer `age` keeps its value and ages above 120 are stored as they came in. Fix: `age = min(age, @max_age)`.

**2. Input creates atoms (security).** Rule: "Convert external strings to atoms with explicit clauses." `role = String.to_atom(params["role"])` lets any caller add atoms to the VM (virtual machine), which has a fixed atom limit and never frees atoms. A missing role also raises here, outside the `try`. Fix: `parse_role/1` with one clause per accepted role and an error clause for anything else.

**3. A `try` hides every error (error handling).** Rule: "Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs." The `rescue _ -> {:error, :invalid}` clause turns every exception into the same answer, including bugs such as a `nil` email reaching `String.downcase/1`. `String.to_integer(params["age"])` raises on text like `"abc"` and relies on that rescue. Fix: remove the `try` and parse with `Integer.parse/1`, which returns a tuple.

**4. Check, then insert, for uniqueness (correctness).** Rule: "Validate input with changesets" (Ecto is the Elixir database library). `if Repo.get_by(User, email: email) == nil` runs a lookup before the insert. Two imports of the same email can both pass the check, and one insert then fails. Fix: declare `unique_constraint(:email)` in `User.changeset/2` and let the insert return `{:error, changeset}`.

**5. Struct inserted without a changeset (correctness).** Rule: "Validate input with changesets." `user = %User{email: email, age: age, role: role, nickname: nickname}` followed by `Repo.insert(user)` skips validation, and a constraint violation raises. Fix: `%User{} |> User.changeset(attrs) |> Repo.insert()`.

**6. Catch-all error hides the cause (error handling).** Rule: "Match every expected shape and let unexpected ones crash." `_ -> {:error, :insert_failed}` drops the changeset that explains the failure. Fix: match `{:error, changeset}` and return it.

**7. Nested `if` chain with one vague error (readability).** Rule: "Chain fallible steps with `with`; normalize each step's error in a small private function." The function has four levels of nesting, and `{:error, :invalid}` is returned for an email already taken, an underage user, and a bad age alike. Callers cannot tell these apart. Fix: a `with` chain over small helpers, each returning `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}`.

**8. Boolean operators on non-booleans (readability).** Rule: "Use `and`, `or`, `not` when the operands are booleans." `is_binary(email) && age >= 18` uses `&&` where both sides are booleans. Fix: the `with` chain checks each field in turn, so the `&&` line goes away.

**9. Return shape depends on an option (API).** Rule: "Give each function one return shape." `if opts[:return_id], do: user.id, else: {:ok, user}` makes `import_user/2` return a bare integer or a tuple. Fix: `import_user_id/2` returns the ID, and `import_user/2` always returns a tuple.

**10. Overlapping booleans (API).** Rule: "Use one atom-valued field or option instead of overlapping booleans." `opts[:notify] && !opts[:silent]` makes `silent` a veto on `notify`, so the combination `notify: true, silent: true` means something different from either option alone. Fix: drop `:silent`; `notify: true` alone decides.

**11. Options are not checked or documented (API).** Rule: "Group related parameters." `opts \\ []` is read with `opts[:key]` and never checked, and there is no `## Options` section. Fix: `Keyword.validate!(opts, notify: false)`, and document `:notify` in `@doc`. Unknown options now raise, so callers that pass `return_id:` or `silent:` must change.

**12. Bare `spawn` (processes).** Rule: "Supervise every long-lived process." `spawn(fn -> Mailer.deliver(welcome_email(user)) end)` runs outside any supervisor, so a crash is not reported or restarted. Fix: `Task.Supervisor.start_child/2` under a supervisor named in the application's supervision tree.

**13. Access syntax on a struct (correctness).** Rule: "Read required keys with `map.key` or a pattern." `user[:name]` raises `UndefinedFunctionError`, because structs do not implement Access. Fix: `user.nickname`. The `|| "there"` default is dropped because `nickname` is always set to a value (it falls back to the email).

**14. Pipe into an anonymous function (readability).** Rule: "Do not pipe into an anonymous function call." `greeting |> (fn text -> text <> " Enjoy your account." end).()` is hard to read, and the `greeting` variable only exists for it. Fix: one interpolated string, `"Hi #{user.nickname}, welcome! Enjoy your account."`.

**15. Single-step pipe (readability).** Rule: "Do not pipe a single step." `params["email"] |> String.downcase()` becomes `String.downcase(email)` after the field check.

**16. Magic numbers (readability).** Rule: "Name magic numbers with module attributes." `120` and `18` appear inline. Fix: `@max_age 120` and `@min_age 18`.

**17. Comments restate code, and the docs are missing (documentation).** Rule: "Comments explain why; documentation goes in `@moduledoc` and `@doc`." Lines 2, 5, 7 and 48 restate what the code says, and the module and public function have no `@moduledoc` or `@doc`. Fix: add both, delete the restating comments, and keep the comment that explains why the email is lowercased.

## Assumptions in the improved version

- `User.changeset/2` exists, casts the fields and declares `unique_constraint(:email)`. The module was not provided.
- `User` has a `nickname` field and no `name` field.
- `Accounts.TaskSupervisor` is started in the application's supervision tree.
- The roles `:admin`, `:editor` and `:member` are placeholders. Replace them with the roles the application defines.

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

  Returns `{:ok, user}`, or `{:error, reason}` when a field is missing or
  invalid, or when the email is already taken.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, attrs} <- parse_attrs(params),
         {:ok, user} <- insert_user(attrs) do
      if opts[:notify], do: send_welcome(user)

      {:ok, user}
    end
  end

  @doc """
  Imports one user and returns its ID (identifier).

  Takes the same options as `import_user/2`.
  """
  def import_user_id(params, opts \\ []) do
    with {:ok, user} <- import_user(params, opts), do: user.id
  end

  defp parse_attrs(params) do
    with {:ok, email} <- string_field(params, "email"),
         {:ok, age} <- integer_field(params, "age"),
         {:ok, age} <- check_adult(age),
         {:ok, role_text} <- string_field(params, "role"),
         {:ok, role} <- parse_role(role_text) do
      # The provider lowercases addresses before its uniqueness check, so match it here
      email = String.downcase(email)

      attrs = %{
        email: email,
        age: min(age, @max_age),
        role: role,
        nickname: params["nickname"] || email
      }

      {:ok, attrs}
    end
  end

  defp insert_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp string_field(params, key) do
    case params[key] do
      nil -> {:error, {:missing_field, key}}
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, {:invalid_field, key}}
    end
  end

  defp integer_field(params, key) do
    with {:ok, text} <- string_field(params, key) do
      parse_integer(text, key)
    end
  end

  defp parse_integer(text, key) do
    case Integer.parse(text) do
      {value, ""} -> {:ok, value}
      {_value, _rest} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:invalid_field, key}}
    end
  end

  defp check_adult(age) when age >= @min_age, do: {:ok, age}
  defp check_adult(_age), do: {:error, {:invalid_field, "age"}}

  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("editor"), do: {:ok, :editor}
  defp parse_role("member"), do: {:ok, :member}
  defp parse_role(other), do: {:error, {:unknown_role, other}}

  defp send_welcome(user) do
    email = welcome_email(user)

    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```
