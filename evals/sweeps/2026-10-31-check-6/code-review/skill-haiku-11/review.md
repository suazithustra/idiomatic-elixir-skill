# Review: `Accounts.UserImporter`

## Findings

1. **Ages above 120 are never capped.** The `age = 120` on lines 15–17 is set inside an `if`, and a value assigned inside an `if` does not leave it, so `age` keeps the original number. Fix: `age = min(age, @max_age)`. Rule, `SKILL.md`, "Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it".

2. **A welcome email crashes the import when `notify: true`.** Line 53, `user[:name]`, runs on a `%User{}` struct, and structs do not implement Access (the `[]` lookup). The call raises `UndefinedFunctionError`. Fix: greet with `user.nickname`, which is always set because it defaults to the email. Rule, `SKILL.md`, "Read required keys with `map.key` or a pattern; keep `map[:key]` for optional keys": "Structs do not implement `Access`: `user[:name]` raises `UndefinedFunctionError`, so read struct fields with `user.name` or a pattern."

3. **A catch-all `rescue` hides every error, including bugs.** Lines 10–44 turn any exception into `{:error, :invalid}`. The rescue exists because `String.to_integer/1` on line 13 raises on bad input. Fix: parse with `Integer.parse/1` and check each field explicitly, then delete the `try`. Rule, `SKILL.md`, "Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs".

4. **The `return_id` option changes what the function returns.** Line 31 returns a bare ID when the option is set and `{:ok, user}` otherwise. Fix: remove the option; callers read `user.id` from the `{:ok, user}` tuple. Rule, `SKILL.md`, "Give each function one return shape" (in "Group related parameters"). This is a breaking change: a caller that still passes `return_id:` now raises from `Keyword.validate!/2`.

5. **The duplicate-email check races, and the insert skips validation.** Lines 22–25 build a raw `%User{}` and check `Repo.get_by/2` before inserting. Two imports of the same address can both pass the check, and nothing validates the fields before the insert. Fix: insert through `User.changeset/2` with `unique_constraint(:email)`, and add a unique index on `email` in a migration. Rule, `references/ecto-phoenix.md`, "Validate input with changesets": "Declare database constraints in the changeset (`unique_constraint/3`, and `foreign_key_constraint/3` or `assoc_constraint/3` for a `belongs_to`) so a violation returns `{:error, changeset}` instead of raising."

6. **Four different failures return the same `:invalid` reason, and a `_ ->` clause hides insert failures.** Lines 37 and 40 return `:invalid` for a duplicate, an underage user, and bad input alike. Lines 33–34 turn any other `Repo.insert/1` result into `:insert_failed`. Fix: return changeset errors from the insert and `{:missing_field, key}` or `{:invalid_field, key}` for input. Rule, `SKILL.md`, "Match every expected shape and let unexpected ones crash": "Different failures need different reasons too: a caller cannot tell a missing field from a bad number when both return `{:error, :invalid}`."

7. **`String.to_atom/1` turns external input into atoms.** Line 8 lets anyone who controls the input add atoms until the VM's atom limit crashes the node. When `role` is missing, `String.to_atom(nil)` also raises outside the `try`. Fix: declare `role` as an `Ecto.Enum` field in `User` and cast the string. Ecto converts only the listed values. Rule, `SKILL.md`, "Convert external strings to atoms with explicit clauses".

8. **`spawn/1` runs the mailer with no supervisor.** Line 49 starts an unlinked process. If delivery crashes, nothing logs or restarts it, and it does not show in supervision tools. Fix: `Task.Supervisor.start_child/2` under a supervisor in the application tree (assumed to be `Accounts.TaskSupervisor`). Rule, `references/processes.md`, the row "Fire-and-forget work" in "Pick the abstraction that matches the job": "`Task.Supervisor.start_child/2`".

9. **Required fields are read with brackets and never checked.** Lines 8, 12 and 13 read `params["role"]`, `params["email"]` and `params["age"]`. A missing email becomes `nil`, and `String.downcase(nil)` then raises. Fix: small `string_field/2` and `integer_field/2` helpers, chained with `with`, that return `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}`. Rule, `SKILL.md`, "Parse external data into structs where it enters the system": "check the fields one at a time in small functions chained with `with`, each returning `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}`."

10. **Nested `if` and `case` blocks make the flow hard to follow.** Lines 15–41 nest four levels deep. Fix: one `with` for parse, insert and notify, with each step in a private function. Rule, `SKILL.md`, "Chain fallible steps with `with`; normalize each step's error in a small private function".

11. **`notify` and `silent` overlap.** Line 27 reads `opts[:notify] && !opts[:silent]`. Passing both makes no sense, and the code has to resolve the conflict. Fix: remove `silent`, since `notify` already defaults to `false`. Rule, `SKILL.md`, "Use one atom-valued field or option instead of overlapping booleans". This is a behavior change: a caller that passes `notify: true, silent: true` now gets an email.

12. **Boolean operators on booleans.** Lines 21 and 27 use `&&` and `!`. Fix: `and` and `not`. The `is_binary(email)` check on line 21 goes away with the parsing step. Rule, `SKILL.md`, "Use `and`, `or`, `not` when the operands are booleans".

13. **A pipe into an anonymous function, and a pipe with one step.** Line 55 pipes a string into `(fn ... end).()`, and line 12 pipes one call. Fix: one interpolated string on line 54, and a plain call. Rule, `SKILL.md`, "Do not pipe into an anonymous function call (`|> (fn x -> ... end).()`)". Also "Do not pipe a single step: write `String.trim(name)`, not `name |> String.trim()`."

14. **Comments restate the code, and the docs are comments.** Lines 2 and 5 describe the module and a function, and lines 7 and 48 restate the next line. Fix: `@moduledoc` and `@doc`, with the restating comments deleted. Line 11 gives a reason and stays. Rule, `SKILL.md`, "Comments explain why; documentation goes in `@moduledoc` and `@doc`": "Document modules and public functions with `@moduledoc` and `@doc`, not with comments above them."

15. **Options are not checked and the public function has no `@spec`.** Line 6 takes `opts` without validating its keys. Fix: `Keyword.validate!(opts, notify: false)` and a `@spec`. Rules, `SKILL.md`, "Group related parameters": "check them with `Keyword.validate!/2`"; `references/library-design.md`, "Add specs, and hide technical functions from the docs": "Give every public function a `@spec`".

## Improved version

Lines 1–3 of the module and the `User` schema are assumed. The improved code relies on these, which are not in the input:

- `Accounts.User` has `email`, `age`, `role` (an `Ecto.Enum`) and `nickname` fields, and a `changeset/2` as shown below.
- A unique index on `users.email` exists in the database.
- `Accounts.TaskSupervisor` is a `Task.Supervisor` in the application tree.
- `Mailer.deliver/1` is unchanged.

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external source, such as a CSV (comma-separated values)
  or JSON (JavaScript Object Notation) export.
  """

  alias Accounts.{Repo, User}

  @max_age 120

  @doc """
  Imports one user from string-keyed params.

  Returns `{:ok, user}`, or `{:error, reason}` where the reason is
  `{:missing_field, key}` or `{:invalid_field, key}` for a bad input field,
  or an `Ecto.Changeset` when validation fails or the email is already taken.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  @spec import_user(map(), keyword()) ::
          {:ok, %User{}}
          | {:error, Ecto.Changeset.t() | {:missing_field | :invalid_field, String.t()}}
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, attrs} <- parse_params(params),
         {:ok, user} <- insert_user(attrs) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  defp parse_params(params) do
    with {:ok, email} <- string_field(params, "email"),
         {:ok, age} <- integer_field(params, "age"),
         {:ok, role} <- string_field(params, "role") do
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
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp integer_field(params, key) do
    with {:ok, text} <- string_field(params, key) do
      case Integer.parse(text) do
        {integer, ""} -> {:ok, integer}
        {_integer, _rest} -> {:error, {:invalid_field, key}}
        :error -> {:error, {:invalid_field, key}}
      end
    end
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

The `User` module this relies on:

```elixir
defmodule Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :age, :integer
    field :role, Ecto.Enum, values: [:admin, :editor, :member]
    field :nickname, :string
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :age, :role, :nickname])
    |> validate_required([:email, :age, :role])
    |> validate_number(:age, greater_than_or_equal_to: 18)
    |> unique_constraint(:email)
  end
end
```

The role values in `Ecto.Enum` are placeholders. Replace them with the roles the application uses.
