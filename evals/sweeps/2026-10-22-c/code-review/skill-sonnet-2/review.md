# Review: `Accounts.UserImporter`

Reference files read: `processes.md` (`spawn`), `ecto-phoenix.md` (`Repo`), `library-design.md` (public API).

## Findings

1. **Convert external strings to atoms with explicit clauses.** `role = String.to_atom(params["role"])` lets input exhaust the atom table, and it raises on a missing role (`nil`) outside any error handling. Fix: `role_atom("admin") -> {:ok, :admin}` and so on, ending in `{:error, {:invalid_field, "role"}}`.
2. **Return `{:error, reason}` for expected failures; no `try/rescue` around a whole function.** `rescue _ -> {:error, :invalid}` hides bugs (including the `FunctionClauseError`s and `KeyError`s a typo would cause) and collapses every failure into `:invalid`. Fix: non-raising parsing (`Integer.parse/1`) and one step per field.
3. **Match every expected shape and parse at the boundary.** `String.to_integer(params["age"])` and `params["email"] |> String.downcase()` crash on missing or malformed input. Fix: `string_field/2`, `parse_age/1` and `parse_role/1` chained with `with`, returning `{:missing_field, key}` or `{:invalid_field, key}`.
4. **Rebinding inside a block does not escape it.** `if age > 120 do age = 120 end` never changes `age`, so the cap is dead code. Fix: `min(age, @max_age)`. The magic numbers become a named attribute (`@max_age`).
5. **`&&` with boolean operands, and the check comes too late.** `is_binary(email) && age >= 18` runs after `String.downcase/1` has already raised for non-binaries, so it can never be false. `&&` also hides intent. Fix: `string_field/2` checks the type first. The age rule moves into the changeset.
6. **Validate with changesets, not a `%User{}` passed to `Repo.insert/1`.** Nothing is validated, and a constraint violation raises. Fix: `User.changeset/2` (casting, `validate_number(:age, greater_than_or_equal_to: 18)`, `unique_constraint(:email)`).
7. **Lookup before insert instead of `unique_constraint/3`.** `Repo.get_by(User, email: email) == nil` followed by an insert is a race, and it costs an extra query. Fix: `unique_constraint(:email)` in the changeset, which returns `{:error, changeset}`.
8. **`_ ->` clause on `Repo.insert/1`.** It throws away the changeset errors as `:insert_failed`. Fix: pass `{:error, changeset}` through unchanged.
9. **Nested `if`/`case`.** Four levels deep in one function. Fix: a short `import_user/2` with a two-step `with` and private helpers.
10. **Overlapping booleans.** `opts[:notify] && !opts[:silent]` has a meaningless combination. Fix: a single `:notify` option, validated with `Keyword.validate!/2` and documented under `## Options`.
11. **One return shape per function.** `opts[:return_id]` makes the function return a bare id or `{:ok, user}`. Fix: always return `{:ok, user}`. Callers that want the id read `user.id`.
12. **`user[:name]` on a struct.** Structs don't implement `Access`, so this raises `UndefinedFunctionError`. The struct also has no `:name` field (assumed from the original constructor). Fix: use `user.nickname`.
13. **Pipe into an anonymous function.** `greeting |> (fn text -> ... end).()` is needless. Fix: a single interpolated string.
14. **Bare `spawn/1` for the email.** The process is unsupervised, so a crash is lost and shutdown can drop the mail. Fix: `Task.Supervisor.start_child(Accounts.TaskSupervisor, ...)`. The supervisor must be in the application's tree: `{Task.Supervisor, name: Accounts.TaskSupervisor}`. The closure captures only `user`, which is small.
15. **Comments that restate code, and no docs.** Removed `# Get the role from params`, `# send the email` and similar. Replaced the `#` header comments with `@moduledoc`, `@doc` (options and return values) and `@spec`. The useful "provider lowercases addresses" reason is kept as a comment on the downcase step.
16. **Alias style.** `alias Accounts.{Repo, User}` is split into one alias per line, to match the skill's examples.

Assumptions: `User` is an Ecto schema with an `Ecto.Enum` `:role` (values `:admin`, `:editor`, `:member`, which are placeholders to adjust) and a `@type t`. `Mailer` is an existing module. Nothing was compiled, because the surrounding project is missing.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from string-keyed params, such as rows of an external CSV or JSON source.
  """

  alias Accounts.Repo
  alias Accounts.User

  @max_age 120

  @doc """
  Imports a single user from string-keyed `params`.

  Returns `{:ok, user}`, `{:error, {:missing_field, key}}`,
  `{:error, {:invalid_field, key}}`, or `{:error, changeset}` when validation
  or the unique email constraint fails. Ages above #{@max_age} are clamped.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  @spec import_user(map(), keyword()) ::
          {:ok, User.t()}
          | {:error, {:missing_field | :invalid_field, String.t()}}
          | {:error, Ecto.Changeset.t()}
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
         {:ok, age} <- parse_age(params),
         {:ok, role} <- parse_role(params) do
      # The provider lowercases addresses before its uniqueness check, so match it here
      email = String.downcase(email)

      {:ok, %{email: email, age: age, role: role, nickname: params["nickname"] || email}}
    end
  end

  defp insert_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp string_field(params, key) do
    case params do
      %{^key => value} when is_binary(value) -> {:ok, value}
      %{^key => _value} -> {:error, {:invalid_field, key}}
      %{} -> {:error, {:missing_field, key}}
    end
  end

  defp parse_age(params) do
    case params do
      %{"age" => age} when is_integer(age) -> {:ok, min(age, @max_age)}
      %{"age" => age} when is_binary(age) -> parse_age_string(age)
      %{"age" => _age} -> {:error, {:invalid_field, "age"}}
      %{} -> {:error, {:missing_field, "age"}}
    end
  end

  defp parse_age_string(text) do
    case Integer.parse(text) do
      {age, ""} -> {:ok, min(age, @max_age)}
      {_age, _rest} -> {:error, {:invalid_field, "age"}}
      :error -> {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_role(params) do
    with {:ok, role} <- string_field(params, "role") do
      role_atom(role)
    end
  end

  defp role_atom("admin"), do: {:ok, :admin}
  defp role_atom("editor"), do: {:ok, :editor}
  defp role_atom("member"), do: {:ok, :member}
  defp role_atom(_other), do: {:error, {:invalid_field, "role"}}

  defp send_welcome(user) do
    {:ok, _pid} =
      Task.Supervisor.start_child(Accounts.TaskSupervisor, fn ->
        Mailer.deliver(welcome_email(user))
      end)

    :ok
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

Companion change in `Accounts.User` (finding 6 and 7):

```elixir
def changeset(user, attrs) do
  user
  |> cast(attrs, [:email, :age, :role, :nickname])
  |> validate_required([:email, :age, :role, :nickname])
  |> validate_number(:age, greater_than_or_equal_to: 18)
  |> unique_constraint(:email)
end
```
