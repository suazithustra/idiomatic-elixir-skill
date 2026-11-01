# Review of `Accounts.UserImporter`

I read `SKILL.md`, `references/processes.md` (the code calls `spawn`) and `references/ecto-phoenix.md` (it calls `Repo`). I did not compile or format the code: no Elixir run was attempted.

## Findings

1. **Unbounded atom creation.** Rule: convert external strings to atoms with explicit clauses. `role = String.to_atom(params["role"])` lets anyone who controls the input exhaust the VM's atom table. It also raises on a missing role. Fix: `role_from_name/1` with one clause per accepted role and `{:error, {:unknown_role, other}}` for the rest.

2. **`try/rescue` around the whole function.** Rule: return tuples for expected failures; never `rescue _ ->` around a function. `rescue _ -> {:error, :invalid}` hides every bug, including typos, and turns bad input into the same `:invalid`. Fix: use `Integer.parse/1` and `Map.fetch/2`, which return values instead of raising, and delete the `try`.

3. **Rebinding inside `if` does not escape it.** Rule: assign the result of `if`. In `if age > 120 do age = 120 end`, the outer `age` stays unchanged, so the cap on age never applied. Fix: `min(age, @max_age)`, with the number named by the module attribute.

4. **Lookup before insert.** Rule: declare `unique_constraint/3` instead of building the check by hand. `Repo.get_by(User, email: email) == nil` followed by `Repo.insert/1` races: two imports can both pass the check. Fix: `unique_constraint(:email)` in `User.changeset/2`; a duplicate then returns `{:error, changeset}`.

5. **Struct inserted without validation.** Rule: validate input with changesets. `%User{email: ..., age: ...}` goes to `Repo.insert/1` unvalidated, and a constraint violation raises. The hand-written `age >= 18` check belongs in `validate_number/3`. Fix: `%User{} |> User.changeset(attrs) |> Repo.insert()`.

6. **`_ ->` clause and uniform error reasons.** Rule: match every expected shape; different failures need different reasons. `_ -> {:error, :insert_failed}` throws away the changeset, and `{:error, :invalid}` is returned for a duplicate, a young user and a bad number alike. Fix: the changeset error passes through, and the field errors are `{:missing_field, key}`, `{:invalid_field, key}` and `{:unknown_role, role}`.

7. **Required keys read with `params["key"]`.** Rule: required keys are checked one at a time and chained with `with`. `params["email"] |> String.downcase()` raises `FunctionClauseError` on `nil`, and the error was swallowed by the `rescue`. Fix: `fetch_string/2`, `parse_age/1` and `parse_role/1`, chained with `with`; each returns a tagged error.

8. **`&&` and `!` on booleans.** Rule: use `and`, `or`, `not` for booleans. `is_binary(email) && age >= 18` becomes `and`. The check was also dead code, since `String.downcase/1` had already raised on a non-binary. Fix: the check is removed, because `fetch_string/2` guarantees a binary.

9. **Overlapping booleans `notify` and `silent`.** Rule: use one option instead of overlapping booleans. `notify: true, silent: true` makes no sense. Fix: only `:notify`, validated with `Keyword.validate!/2` and documented under `## Options`. `opts[:notify] && !opts[:silent]` is gone.

10. **Two return shapes.** Rule: one return shape per function. `:return_id` made `import_user/2` return either a bare id or `{:ok, user}`. Fix: always `{:ok, user}`; callers read `user.id`.

11. **Nested `if`/`case`/`if`.** Rule: keep functions short and at one level of detail. Four levels of nesting are now a flat `with` of named steps, with the details in private functions below.

12. **Bare `spawn/1`.** Rule: supervise every long-lived process; use `Task.Supervisor.start_child/2` for fire-and-forget work. A crash in `Mailer.deliver/1` was invisible and unsupervised. Fix: `Task.Supervisor.start_child(Accounts.TaskSupervisor, ...)`. This needs `{Task.Supervisor, name: Accounts.TaskSupervisor}` in the application's supervision tree. I could not see that tree; add it if it is missing. The closure now captures only the email text, not the whole user.

13. **`user[:name]` on a struct.** Rule: structs do not implement `Access`. `user[:name]` raises `UndefinedFunctionError`, so the welcome email always crashed inside the spawned process, unseen. The struct built here has no `name` field, so I use `user.nickname`. Replace it if `User` has a real name field.

14. **Pipe into an anonymous function.** Rule: do not pipe into `(fn ... end).()`. Fix: one interpolated string. The `name` and `greeting` temporaries are gone.

15. **Comments and docs.** Rule: comments explain why; docs go in `@moduledoc` and `@doc`. `# Get the role from params`, `# send the email` and the two header comments restate code or are documentation. Fix: `@moduledoc` and `@doc` with `## Options`. The one comment that explains a reason (the provider downcases emails) moved into `@doc`. Aliases are sorted, and the 120 magic number is `@max_age`.

16. **Database access outside a context (not changed).** The reference says controllers and jobs should call context functions, not `Repo`. This module is the import boundary, so I left `Repo` here. If the project has an `Accounts` context, move `insert_user/4` into it.

## Companion change needed in `User`

The improved module assumes this changeset exists; the original code had none.

```elixir
def changeset(user, attrs) do
  user
  |> cast(attrs, [:email, :age, :role, :nickname])
  |> validate_required([:email, :age, :role])
  |> validate_number(:age, greater_than_or_equal_to: 18)
  |> unique_constraint(:email)
end
```

The database needs a unique index on the lowercased email for `unique_constraint(:email)` to work. Use `Ecto.Enum` for `role` in the schema if it is not already.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from string-keyed params, as decoded from CSV or JSON.
  """

  alias Accounts.Mailer
  alias Accounts.Repo
  alias Accounts.User

  @max_age 120

  @doc """
  Imports a single user from string-keyed `params`.

  Requires `"email"`, `"age"` and `"role"`; `"nickname"` is optional and
  defaults to the email. The email is downcased because the provider
  downcases addresses before its uniqueness check. Ages above 120 are
  capped at 120.

  Returns `{:ok, user}`, `{:error, {:missing_field, key}}`,
  `{:error, {:invalid_field, key}}`, `{:error, {:unknown_role, role}}` or
  `{:error, changeset}`.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, email} <- fetch_string(params, "email"),
         {:ok, age} <- parse_age(params),
         {:ok, role} <- parse_role(params),
         {:ok, user} <- insert_user(params, email, age, role) do
      if opts[:notify], do: send_welcome(user)

      {:ok, user}
    end
  end

  defp insert_user(params, email, age, role) do
    email = String.downcase(email)

    attrs = %{
      email: email,
      age: age,
      role: role,
      nickname: params["nickname"] || email
    }

    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp fetch_string(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) ->
        {:ok, value}

      {:ok, _value} ->
        {:error, {:invalid_field, key}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end

  defp parse_age(params) do
    with {:ok, text} <- fetch_string(params, "age"),
         {:ok, age} <- parse_integer(text, "age") do
      {:ok, min(age, @max_age)}
    end
  end

  defp parse_integer(text, key) do
    case Integer.parse(text) do
      {integer, ""} ->
        {:ok, integer}

      {_integer, _rest} ->
        {:error, {:invalid_field, key}}

      :error ->
        {:error, {:invalid_field, key}}
    end
  end

  defp parse_role(params) do
    with {:ok, name} <- fetch_string(params, "role") do
      role_from_name(name)
    end
  end

  defp role_from_name("admin"), do: {:ok, :admin}
  defp role_from_name("editor"), do: {:ok, :editor}
  defp role_from_name("member"), do: {:ok, :member}
  defp role_from_name(other), do: {:error, {:unknown_role, other}}

  defp send_welcome(user) do
    message = welcome_email(user)

    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(message) end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

The role names `admin`, `editor` and `member` are placeholders, since the input does not list the valid roles. Replace them with the real set.
