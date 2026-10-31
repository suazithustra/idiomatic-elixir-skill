# Review: `Accounts.UserImporter`

I did not compile or run the improved code. `Accounts.User`, `Accounts.Repo`, `Mailer` and `Accounts.TaskSupervisor` are not in the input file, so the assumptions are listed after the code.

## Findings

1. **Atom exhaustion** (Convert external strings to atoms with explicit clauses). `role = String.to_atom(params["role"])` lets the input create atoms without limit, and raises on `nil`. Fix: `parse_role/1` with one clause per accepted role, and `{:error, {:invalid_field, "role"}}` for anything else.

2. **`try/rescue _ ->` around the whole function** (Return tuples for expected failures; never `rescue _`). It turns every bug into `{:error, :invalid}`, including `String.to_integer(nil)`, a database error and a typo. Fix: remove it. Use `Integer.parse/1` in `parse_age/1`, which returns a tuple.

3. **`age = 120` inside `if` has no effect** (Assign the result of `if`; rebinding inside a block does not escape it). The inner `age` is local to the `if`, so ages above 120 are never capped, and the compiler warns about an unused variable. Fix: `min(age, @max_age)` in `parse_age/1`, with `@max_age 120` naming the number.

4. **`is_binary(email)` is checked after `String.downcase(email)`** (Parse external data where it enters). A non-binary email raises before the check runs. Fix: `parse_email/1` guards with `is_binary/1` first, then downcases. The reason for downcasing stays as a comment.

5. **`&&` and `!` on booleans** (Use `and`, `or`, `not` when the operands are booleans). `is_binary(email) && age >= 18` and `opts[:notify] && !opts[:silent]`. Fix: the first check moves into `parse_email/1` and the changeset (finding 7). The second goes away with finding 6.

6. **Overlapping boolean options and an option that changes the return shape** (Use one atom-valued field instead of overlapping booleans; Give each function one return shape). `notify: true, silent: true` is contradictory, and `return_id: true` returns an id where otherwise `{:ok, user}` comes back. Fix: only `notify`, checked with `Keyword.validate!/2` and documented under `## Options`. Callers that want the id read `user.id` from `{:ok, user}`. A caller still passing `silent:` or `return_id:` now gets an `ArgumentError` at the call, which is the intent.

7. **Struct built by hand and passed to `Repo.insert/1`** (Validate input with changesets). Nothing is validated, and the `age >= 18` check is hand-written. Fix: `User.changeset/2` casts the fields and validates the age (see the companion changeset below). Only the importer's own rules stay here: parsing, the age cap and the email downcase.

8. **Lookup before insert** (`unique_constraint/3` instead of `Repo.get_by` then `Repo.insert`). The check and the insert are two steps, so two concurrent imports of the same email both pass the check and one insert raises. Fix: `unique_constraint(:email)` in the changeset, so the second insert returns `{:error, changeset}`. This needs a unique index on `email`.

9. **`_ -> {:error, :insert_failed}` and one reason for all failures** (Match every expected shape; different failures need different reasons). `:insert_failed` hid the changeset errors, and `:invalid` covered a duplicate, a bad age and a bug alike. Fix: the insert returns `{:ok, user}` or `{:error, changeset}`, and `with` passes errors through unchanged. The other failures name the field: `{:error, {:invalid_field, "age"}}`, or `{:error, :invalid_params}` when a required key is missing.

10. **Required string keys read with `params["key"]`** (Match the required keys of string-keyed input in a function head). Fix: `import_user/2` matches `"email"`, `"age"` and `"role"` in its head, with `import_user(_params, _opts)` below it for everything else. `"nickname"` is optional, so it stays `params["nickname"]`.

11. **Unsupervised `spawn/1` capturing the whole `user`** (Supervise every long-lived process; send processes only the data they need). The mail job runs outside any supervisor and copies the full struct into the new process. Fix: `Task.Supervisor.start_child/2` under `Accounts.TaskSupervisor`, and the closure captures only the finished message string.

12. **`user[:name]` on a struct** (Read required keys with `map.key`). Structs do not implement `Access`, so this raises `UndefinedFunctionError` every time and the welcome mail never goes out. Fix: read `user.nickname`, which the importer always sets.

13. **Pipe into an anonymous function** (`greeting |> (fn text -> ... end).()`) and a one-step pipeline of string concatenation. Fix: one interpolated string in `welcome_message/1`.

14. **Nested `if`/`case`/`if`** (Keep functions short; one level of detail). Five levels deep in one function. Fix: a `with` of four named steps, each in a small private function.

15. **Comments and docs.** `# This module imports users...` and `# Import a single user...` are comments where `@moduledoc` and `@doc` belong. `# Get the role from params` and `# send the email` restate the code. The comment about the provider lowercasing addresses explains a reason, so it stays. Added `@spec`.

16. **Names.** `data`-style temporaries are fine here, but `welcome_email/1` returned a text, not an email, so it is now `welcome_message/1`.

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

  `params` must hold `"email"`, `"age"` and `"role"`; `"nickname"` is optional
  and defaults to the email.

  Returns `{:ok, user}`, `{:error, {:invalid_field, name}}` for a field that
  cannot be parsed, `{:error, :invalid_params}` when a required key is missing,
  or `{:error, changeset}` when validation or the unique email constraint fails.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, term()}
  def import_user(params, opts \\ [])

  def import_user(%{"email" => email, "age" => age, "role" => role} = params, opts) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, role} <- parse_role(role),
         {:ok, age} <- parse_age(age),
         {:ok, email} <- parse_email(email),
         {:ok, user} <- insert_user(email, age, role, params["nickname"] || email) do
      if opts[:notify], do: send_welcome(user)

      {:ok, user}
    end
  end

  def import_user(_params, _opts), do: {:error, :invalid_params}

  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("editor"), do: {:ok, :editor}
  defp parse_role("member"), do: {:ok, :member}
  defp parse_role(_role), do: {:error, {:invalid_field, "role"}}

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

  # The provider lowercases addresses before its uniqueness check, so match it here
  defp parse_email(email) when is_binary(email), do: {:ok, String.downcase(email)}
  defp parse_email(_email), do: {:error, {:invalid_field, "email"}}

  defp insert_user(email, age, role, nickname) do
    attrs = %{email: email, age: age, role: role, nickname: nickname}

    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp send_welcome(user) do
    message = welcome_message(user)

    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(message) end)
  end

  defp welcome_message(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

### Companion changeset (in `Accounts.User`, not in the input file)

```elixir
def changeset(user, attrs) do
  user
  |> cast(attrs, [:email, :age, :role, :nickname])
  |> validate_required([:email, :age, :role])
  |> validate_number(:age, greater_than_or_equal_to: 18)
  |> unique_constraint(:email)
end
```

## Assumptions to check

- The accepted roles are `admin`, `editor` and `member`. The original accepted any string; replace the three `parse_role/1` rows with the real list, or make `role` an `Ecto.Enum` on the schema.
- `Accounts.User` has a `changeset/2` as above, an `@type t`, a `nickname` field, and a unique index on `email`. The original rejected under-18 users with `{:error, :invalid}`; they now come back as `{:error, changeset}`.
- `Accounts.TaskSupervisor` runs in the application's supervision tree. `Mailer` is kept as written; if it is a module of this application it should be `Accounts.Mailer`.
- Welcome mail now greets the nickname, since `user[:name]` could never work. If `User` has a `name` field, use `user.name` instead.
- I could not run `mix format --check-formatted` on the code. I wrote it in the formatter's layout, but it is unchecked.
