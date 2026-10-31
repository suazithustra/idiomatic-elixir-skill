# Review: `Accounts.UserImporter`

## Findings

1. **Atom exhaustion** (convert external strings to atoms with explicit clauses). `role = String.to_atom(params["role"])` creates an atom from input, and raises on a missing role. Fix: pass the string to the changeset and declare `role` as `Ecto.Enum` on `User`, so an unknown role is a changeset error.

2. **`try/rescue _ ->` around the whole function** (return tuples for expected failures; never `rescue _`). `rescue _ -> {:error, :invalid}` hides real bugs (`KeyError`, `FunctionClauseError`, DB errors) behind one reason. Fix: remove it. Use `Integer.parse/1` and return `{:error, {:invalid_field, "age"}}`.

3. **`String.to_integer/1` and `String.downcase/1` on raw params** (same rule). A missing or non-numeric field raised and was then swallowed. Fix: `parse_age/1`, with the required keys matched in the head of `parse_params/1` and `parse_params(_params), do: {:error, :invalid_params}` below it.

4. **Rebinding inside `if` does not escape it** (assign the result of `if`). In `if age > 120 do age = 120 end` the outer `age` never changes, so the clamp does nothing (the compiler warns about the unused variable). Fix: `min(age, @max_age)`.

5. **`is_binary(email)` checked after `String.downcase(email)`** (guard checks that run too late). `downcase` already raised for a non-binary. Fix: `when is_binary(email)` in the head.

6. **`&&` and `!` on booleans** (`and`/`or`/`not`): `is_binary(email) && age >= 18` and `opts[:notify] && !opts[:silent]`. The age check is now a changeset validation. The `opts` condition is covered by finding 7.

7. **Overlapping boolean options, and an option that changes the return shape** (one atom option instead of overlapping booleans; one return shape per function). `notify: true, silent: true` is meaningless, and `return_id: true` makes the result `user.id` instead of `{:ok, user}`. Fix: keep only `notify`, validate with `Keyword.validate!/2`, always return `{:ok, user}`. A caller who wants the id reads `user.id`.

8. **Lookup before insert, and no changeset** (changesets, `unique_constraint/3`). `Repo.get_by(User, email: email) == nil` followed by `Repo.insert(%User{...})` is a race, since two imports can both pass the check, and the struct is inserted unvalidated. Fix: `User.changeset/2` with `validate_number(:age, ...)` and `unique_constraint(:email)`, then `Repo.insert/1`.

9. **Catch-all `_ ->` and one reason for everything** (match every shape; distinct reasons). `{:error, :insert_failed}` and `{:error, :invalid}` for four different failures drop the cause. Fix: `insert_user/1` returns `{:error, changeset}`; parse errors name the field.

10. **Nested `if`/`case`/`if` in one function** (short functions, one level of detail). Fix: a `with` over `parse_params/1` and `insert_user/1`, with the details in private functions.

11. **Unsupervised `spawn/1`** (supervise every long-lived process, `references/processes.md`). A crash in `Mailer.deliver/1` is invisible and unsupervised. Fix: `Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> ... end)`. `Accounts.TaskSupervisor` must be in the application's supervision tree.

12. **`user[:name]` on a struct** (structs do not implement `Access`). It raises `UndefinedFunctionError`, and `User` has no `name` field here. Fix: use `user.nickname`.

13. **Pipe into an anonymous function** (`greeting |> (fn text -> ... end).()`). Fix: one interpolated string, no pipeline.

14. **Comments and docs** (comments explain why; `@moduledoc`/`@doc`). Deleted `# Get the role from params`, `# send the email`, and the `#` blurbs above the module and function. Added `@moduledoc`, and `@doc` with an `## Options` section. Kept the comment about the provider lowercasing, because it gives a reason.

15. **Magic numbers** (name them with module attributes): `120` is now `@max_age`; `18` is `@min_age` in the changeset.

## Notes

- The file does not define `Accounts.User.changeset/2` or `Mailer`. I assumed the changeset below exists and left `Mailer` as in the original.
- Elixir was available, but the file depends on Ecto and `User`, so I did not compile it. I did not run `mix format`.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from external CSV/JSON params.
  """

  alias Accounts.Repo
  alias Accounts.User

  @max_age 120

  @doc """
  Imports a single user from string-keyed params.

  Requires `"email"`, `"age"` and `"role"`; `"nickname"` is optional and
  defaults to the email. Ages above #{@max_age} are stored as #{@max_age}.

  Returns `{:ok, user}`, `{:error, {:invalid_field, key}}` for an unreadable
  field, `{:error, :invalid_params}` when a required key is missing, or
  `{:error, changeset}` when validation or the unique email constraint fails.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, attrs} <- parse_params(params),
         {:ok, user} <- insert_user(attrs) do
      if opts[:notify], do: send_welcome(user)

      {:ok, user}
    end
  end

  defp parse_params(%{"email" => email, "age" => age, "role" => role} = params)
       when is_binary(email) do
    with {:ok, age} <- parse_age(age) do
      # The provider lowercases addresses before its uniqueness check, so match it here
      email = String.downcase(email)

      {:ok, %{email: email, age: age, role: role, nickname: params["nickname"] || email}}
    end
  end

  defp parse_params(_params), do: {:error, :invalid_params}

  defp parse_age(age) when is_integer(age), do: {:ok, min(age, @max_age)}

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {age, ""} ->
        {:ok, min(age, @max_age)}

      {_age, _rest} ->
        {:error, {:invalid_field, "age"}}

      :error ->
        {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(_age), do: {:error, {:invalid_field, "age"}}

  defp insert_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp send_welcome(user) do
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn ->
      Mailer.deliver(welcome_email(user))
    end)
  end

  defp welcome_email(user), do: "Hi #{user.nickname}, welcome! Enjoy your account."
end
```

Supporting change in `Accounts.User` (with `field :role, Ecto.Enum, values: [...]`):

```elixir
@min_age 18

def changeset(user, attrs) do
  user
  |> cast(attrs, [:email, :age, :role, :nickname])
  |> validate_required([:email, :age, :role])
  |> validate_number(:age, greater_than_or_equal_to: @min_age)
  |> unique_constraint(:email)
end
```
