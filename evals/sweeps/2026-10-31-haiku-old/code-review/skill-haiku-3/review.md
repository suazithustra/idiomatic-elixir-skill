# Review: `Accounts.UserImporter`

## Findings

1. **Age clamp does nothing.** Rule: assign the result of `if`. Line 15 `if age > 120 do age = 120 end` rebinds `age` inside the block, so the outer `age` stays above 120. Fix: `age: min(age, @max_age)` in the attrs.

2. **Role string becomes an atom.** Rule: convert external strings to atoms with explicit clauses. Line 8 `String.to_atom(params["role"])` lets any caller add atoms to the VM (the Erlang runtime, which has a fixed atom limit), and a missing role crashes. Fix: declare `role` as `Ecto.Enum` in the schema, so the changeset maps `"admin"` to `:admin` and rejects anything else.

3. **Blanket rescue hides bugs.** Rule: return tuples for expected failures; `rescue` only specific exceptions. Lines 10 and 42-43 wrap the whole body in `try`/`rescue _ ->`, which turns a `nil` email, a bad age, or a database error into `{:error, :invalid}`. Fix: remove the `try`; use `Integer.parse/1` in place of `String.to_integer/1`, which raises on `"abc"`.

4. **Pipe of a single step.** Rule: do not pipe a single step. Line 12 `params["email"] |> String.downcase()` should be `String.downcase(raw_email)`. Line 12 also runs before the `is_binary(email)` check on line 21, so a non-string email crashes there, not at the check.

5. **Uniqueness checked by hand.** Rule: declare database constraints in the changeset with `unique_constraint/3`. Lines 24-38 run `Repo.get_by` and then `Repo.insert`. Two imports of the same address can both pass the lookup and both insert. Fix: `unique_constraint(:email)` in `User.changeset/2` and a unique index on `users.email`; match the `:email` unique error from the insert.

6. **Catch-all error clause.** Rule: match every expected shape; let unexpected ones crash. Line 33 `_ -> {:error, :insert_failed}` hides every other return value, and drops the changeset that explains why the insert failed. Fix: `{:error, failed} -> {:error, {:insert_failed, failed}}`.

7. **Return shape depends on an option.** Rule: give each function one return shape. Line 31 `if opts[:return_id], do: user.id, else: {:ok, user}` returns a bare integer in one mode and a tuple in the other. Fix: `import_user/2` always returns `{:ok, user}`; a new `import_user_id/2` wraps it.

8. **Overlapping booleans.** Rule: use one atom-valued field or option instead of overlapping booleans. Line 27 `opts[:notify] && !opts[:silent]` lets `silent: true` override `notify: true`. Fix: keep `notify` and remove `silent`. Callers that pass `silent:` now get an `ArgumentError` from `Keyword.validate!/2`; that is a deliberate break and needs a check at each call site.

9. **Errors collapse to one reason.** Rule: use atoms, tagged tuples, or exception structs as error reasons, and name the cause. Lines 34, 37 and 40 all return `{:error, :invalid}`, so a caller cannot tell an underage user from a duplicate. Fix: return `:underage`, `:duplicate_email`, `{:missing_field, key}` or `{:invalid_field, key}`.

10. **Bare `spawn`.** Rule: supervise every long-lived process. Line 49 `spawn(fn -> Mailer.deliver(...) end)` runs outside any supervisor, so a crash is lost and the process does not show in tools such as Observer. Fix: `Task.Supervisor.start_child/4` under `Accounts.TaskSupervisor`, which must be added to the application's supervision tree. The closure captures only the built email, not the user.

11. **Struct read with `Access`.** Rule: structs do not implement `Access`; read struct fields with `user.name` or a pattern. Line 53 `user[:name]` raises `UndefinedFunctionError`, so every welcome email fails. Fix: greet by `user.nickname`, which is set on every import.

12. **Pipe into an anonymous function, and string concatenation.** Rule: do not pipe into an anonymous function call; name the value or use `then/2`. Line 55 `greeting |> (fn text -> ... end).()` adds one sentence in a roundabout way. Fix: a single interpolated string.

13. **Deep nesting in one function.** Rule: keep functions short and at one level of detail; chain fallible steps with `with`, one private function per step. `import_user/2` nests `if`, `case` and `if` four levels deep. Fix: `with` over `parse_attrs/1` and `insert_user/1`, each a small private function.

14. **Magic numbers.** Rule: name magic numbers with module attributes. The numbers 18 and 120 appear inline on lines 21 and 15. Fix: `@min_age 18` and `@max_age 120`.

15. **Comments and docs.** Rule: comments explain why; documentation goes in `@moduledoc` and `@doc`. Lines 2, 5, 7, 48 and 52 restate the code or describe the module in a comment, and the public function has no `@doc`. Fix: `@moduledoc`, `@doc` with `## Options`, and comments only where the reason is not visible (the lowercasing note stays).

## Assumptions in the improved code

- `Accounts.User` must have `email`, `age`, `nickname` and `role` fields, with `role` as `Ecto.Enum` over `[:admin, :member]`. Replace those role values with the project's real roles.
- `User.changeset/2` must cast those fields, call `validate_required/2` on `email`, `age` and `role`, and call `unique_constraint(:email)`. A unique index on `users.email` is needed, or the constraint never fires.
- `Accounts.TaskSupervisor` must be started, as `{Task.Supervisor, name: Accounts.TaskSupervisor}`, in the application's children.

```elixir
defmodule Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :age, :integer
    field :nickname, :string
    field :role, Ecto.Enum, values: [:admin, :member]
    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :age, :nickname, :role])
    |> validate_required([:email, :age, :role])
    |> unique_constraint(:email)
  end
end
```

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from string-keyed params.

  Returns `{:ok, user}` or `{:error, reason}`. Reasons are `{:missing_field, key}`,
  `{:invalid_field, key}`, `:underage`, `:duplicate_email`, or `{:insert_failed, changeset}`.

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
  Like `import_user/2`, but returns the new user's ID instead of the user.
  """
  def import_user_id(params, opts \\ []) do
    case import_user(params, opts) do
      {:ok, user} -> {:ok, user.id}
      {:error, _reason} = error -> error
    end
  end

  defp parse_attrs(params) do
    with {:ok, raw_email} <- string_field(params, "email"),
         {:ok, role} <- string_field(params, "role"),
         {:ok, age} <- integer_field(params, "age"),
         :ok <- check_age(age) do
      # The provider lowercases addresses before its uniqueness check, so match it here
      email = String.downcase(raw_email)

      attrs = %{
        email: email,
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
    case string_field(params, key) do
      {:ok, text} -> parse_integer(text, key)
      {:error, _reason} = error -> error
    end
  end

  defp parse_integer(text, key) do
    case Integer.parse(text) do
      {value, ""} -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp check_age(age) when age >= @min_age, do: :ok
  defp check_age(_age), do: {:error, :underage}

  defp insert_user(attrs) do
    changeset = User.changeset(%User{}, attrs)

    case Repo.insert(changeset) do
      {:ok, _user} = inserted -> inserted
      {:error, failed} -> {:error, insert_error(failed)}
    end
  end

  defp insert_error(changeset) do
    case changeset.errors[:email] do
      {_message, [constraint: :unique, constraint_name: _]} -> :duplicate_email
      _ -> {:insert_failed, changeset}
    end
  end

  defp send_welcome(user) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, Mailer, :deliver, [email])
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```
