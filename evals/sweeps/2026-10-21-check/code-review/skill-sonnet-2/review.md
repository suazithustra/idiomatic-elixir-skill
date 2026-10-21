# Review: Accounts.UserImporter

Assumptions: `Accounts.User` has an `Ecto.Enum` `role` field and a `changeset/2` (sketch at the end). `Accounts.TaskSupervisor` is started in the application's supervision tree. I could not compile this against the real project.

## Findings

1. **`String.to_atom(params["role"])` on external input** (rule: convert external strings to atoms with explicit clauses). `role = String.to_atom(params["role"])` lets anyone who controls the input exhaust the atom table and crash the node, and it raises on a missing role. Fix: pass the string through the changeset and let an `Ecto.Enum` field accept only the listed roles.

2. **Whole function wrapped in `try ... rescue _ ->`** (rule: return tuples for expected failures; never `rescue _`). `rescue _ -> {:error, :invalid}` turns every bug, including a `Repo` outage or a typo, into `:invalid`. Fix: remove the `try`, use `Integer.parse/1` instead of `String.to_integer/1`, and return specific errors.

3. **Rebinding `age` inside `if`** (rule: assign the result of `if`). `if age > 120 do age = 120 end` has no effect: `age` stays unchanged and the compiler warns. Fix: `age: min(age, @max_age)`; the 120 becomes a named attribute.

4. **Struct built from params and passed to `Repo.insert/1`** (rule: validate input with changesets). `%User{email: email, age: age, ...}` skips validation, and a unique-email violation raises. Fix: `User.changeset/2` with `unique_constraint(:email)` and `validate_number(:age, greater_than_or_equal_to: 18)`, so the caller gets `{:error, changeset}`.

5. **Catch-all `_ -> {:error, :insert_failed}`** (rule: match every expected shape). It discards the changeset errors. Fix: pass the `{:error, changeset}` from `Repo.insert/1` through `with` unchanged.

6. **`is_binary(email) && age >= 18`** (rule: `and` for booleans). The check is also useless, because `String.downcase/1` above it already raised for a non-binary. Fix: read and validate fields in small functions that return `{:missing_field, key}` or `{:invalid_field, key}`; the age check moves to the changeset.

7. **Overlapping options `notify` and `silent`** (rule: avoid overlapping booleans). `opts[:notify] && !opts[:silent]` has a meaningless `notify: true, silent: true` case. Fix: keep only `:notify`, validated with `Keyword.validate!/2` and documented under `## Options`.

8. **`return_id` changes the return shape** (rule: one return shape). `if opts[:return_id], do: user.id, else: {:ok, user}` returns an id or a tuple. Fix: remove the option; callers use `user.id`. This breaks callers that pass `return_id: true`.

9. **Bare `spawn/1` for the email** (references/processes.md: supervise processes; send processes only the data they need). A crash in `Mailer.deliver` is unsupervised, and the closure copies the whole `user`. Fix: `Task.Supervisor.start_child/2`, with the email built before the closure.

10. **`user[:name]` on a struct** (rule: structs do not implement `Access`). It raises `UndefinedFunctionError`. The struct built in the original has no `name` field, so the fix greets by `user.nickname`, which is always set. Change this if the real struct has a name field.

11. **Piping into an anonymous function** (rule: no `|> (fn ... end).()`). Replaced by one interpolated string.

12. **Comments and docs** (rule: comments explain why). Removed `# Get the role from params`, `# send the email`, and the `#` comments above the module and function, and replaced them with `@moduledoc` and `@doc`. Kept the comment about the provider lowercasing addresses, since it gives a reason. The single-step pipe `params["email"] |> String.downcase()` is now `String.downcase(email)`.

13. **Nested control flow in one long function** (rule: short functions, one level of detail). `import_user/2` was a `try` holding an `if` holding a `case` holding two `if`s. Split into `build_attrs/1`, `string_field/2`, `integer_field/2`, `parse_integer/2`, `insert_user/1`, `send_welcome/1`. The field readers are named by job, not `fetch`, because they return error reasons.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV/JSON source.
  """

  alias Accounts.{Repo, User}

  @max_age 120

  @doc """
  Imports a single user from string-keyed `params`.

  Returns `{:ok, user}`, `{:error, {:missing_field, key}}`,
  `{:error, {:invalid_field, key}}`, or `{:error, changeset}` when validation
  or a database constraint fails.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, attrs} <- build_attrs(params),
         {:ok, user} <- insert_user(attrs) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  defp build_attrs(params) do
    with {:ok, email} <- string_field(params, "email"),
         {:ok, role} <- string_field(params, "role"),
         {:ok, age} <- integer_field(params, "age") do
      # The provider lowercases addresses before its uniqueness check, so match it here
      email = String.downcase(email)

      {:ok,
       %{
         email: email,
         role: role,
         age: min(age, @max_age),
         nickname: params["nickname"] || email
       }}
    end
  end

  defp string_field(params, key) do
    case params do
      %{^key => value} when is_binary(value) -> {:ok, value}
      %{^key => _value} -> {:error, {:invalid_field, key}}
      %{} -> {:error, {:missing_field, key}}
    end
  end

  defp integer_field(params, key) do
    case params do
      %{^key => value} when is_integer(value) -> {:ok, value}
      %{^key => value} when is_binary(value) -> parse_integer(value, key)
      %{^key => _value} -> {:error, {:invalid_field, key}}
      %{} -> {:error, {:missing_field, key}}
    end
  end

  defp parse_integer(value, key) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _ -> {:error, {:invalid_field, key}}
    end
  end

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
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

## Sketch of the assumed `User` side

```elixir
schema "users" do
  field :email, :string
  field :age, :integer
  field :role, Ecto.Enum, values: [:admin, :member]  # use the real role list
  field :nickname, :string
end

def changeset(user, attrs) do
  user
  |> cast(attrs, [:email, :age, :role, :nickname])
  |> validate_required([:email, :age, :role])
  |> validate_number(:age, greater_than_or_equal_to: 18)
  |> unique_constraint(:email)
end
```
