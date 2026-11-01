# Review: `Accounts.UserImporter`

Assumptions (not visible in the input): `Accounts.User` has `User.changeset/2` and `@type t`; the allowed roles are `admin`, `editor`, `member`; `Accounts.TaskSupervisor` is a `Task.Supervisor` in the supervision tree. A sketch of the changeset the new code needs is at the end. I could not run `mix format` or compile in this session, so the improved code is unformatted-checked and uncompiled.

## Findings

1. **`String.to_atom(params["role"])`** (line 8). Input creates atoms, which are never collected. It also crashes on a missing role. Rule: convert external strings with explicit clauses. Fix: `role_atom("admin")`, `role_atom("editor")`, `role_atom("member")`, and a catch-all returning `{:error, {:invalid_field, "role"}}`.

2. **`try ... rescue _ -> {:error, :invalid}`** (lines 10, 42-43). It hides every bug (a typo, a failed `Repo` call) behind one error. Rule: use non-raising functions; never `rescue _`. Fix: `Integer.parse/1` and pattern matching, chained with `with`.

3. **`if age > 120 do age = 120 end`** (lines 15-17). Rebinding inside `if` does not escape the block, so the cap never applied. Rule: assign the result. Fix: `min(age, @max_age)`, with `120` named as a module attribute.

4. **`String.to_integer(params["age"])`, `String.downcase` on `params["email"]`** (lines 12-13). A missing or non-string value raises, and the `is_binary(email)` check on line 21 runs after `String.downcase` already needed a binary. Rule: match required string-keyed input and report which field is bad. Fix: `parse_email/1` and `parse_age/1`, returning `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}`.

5. **`Repo.get_by(...) == nil` before `Repo.insert`** (line 24). Two imports of the same email can both pass the check, and the second insert then raises. Rule: declare `unique_constraint/3` in the changeset. Fix: remove the lookup; a duplicate returns `{:error, changeset}`.

6. **`Repo.insert(%User{...})` built from params, and `_ -> {:error, :insert_failed}`** (lines 22, 25, 33). Nothing is validated (the age check is by hand), and the catch-all drops the reason. Rule: validate with changesets; match every shape. Fix: `User.changeset/2` then `Repo.insert/1`; the `{:error, changeset}` goes to the caller unchanged.

7. **`&&` and `!` on booleans, and overlapping options `notify`/`silent`** (lines 21, 27). Rules: `and` for boolean operands; one option instead of overlapping booleans. Fix: `age >= 18` moves into the changeset; only `notify: false` remains, checked with `Keyword.validate!/2`.

8. **`opts[:return_id]` changes the return type** (line 31). Returns an id in one mode and `{:ok, user}` in the other. Rule: one return shape. Fix: removed. Callers read `user.id`.

9. **Nested `if` / `case` / `if`, duplicate `{:error, :invalid}`** (lines 21-41). Three levels deep, and two different failures share one reason. Rule: `with` with a small function per step. Fix: flat `with` in `import_user/2`.

10. **`spawn/1` for the welcome email** (line 49). Unsupervised, so a crash is lost and nothing stops it at shutdown; it also copies the whole `user` into the closure. Rule: supervise processes; send only the data needed. Fix: build the email first, then `Task.Supervisor.start_child/2` with a closure that captures only the email.

11. **`user[:name]`** (line 53). Structs do not implement `Access`, so this raises `UndefinedFunctionError` on every call. Rule: structs use dot access. Fix: `user.nickname`, which is always set (it defaults to the email). Change this if you meant a separate `name` field.

12. **`|> (fn text -> ... end).()`** (line 55). Piping into an anonymous function. Rule: do not. Fix: one interpolated string.

13. **Comments and docs** (lines 2, 5, 7, 48). Comments restate the code, and the docs sit in comments. Rule: `@moduledoc` and `@doc`, with `## Options`. Fix: added both and a `@spec`. The comment on the email lowercasing explains a reason and stays.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from parsed CSV or JSON rows.
  """

  alias Accounts.{Repo, User}

  @max_age 120

  @doc """
  Imports a single user from string-keyed `params`.

  Returns `{:ok, user}`, `{:error, {:missing_field, key}}`,
  `{:error, {:invalid_field, key}}`, or `{:error, changeset}` when the
  changeset rejects the user, including a duplicate email.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, term()}
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, role} <- parse_role(params),
         {:ok, email} <- parse_email(params),
         {:ok, age} <- parse_age(params),
         {:ok, user} <- insert_user(%{email: email, age: age, role: role}, params) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  defp insert_user(attrs, params) do
    attrs = Map.put(attrs, :nickname, params["nickname"] || attrs.email)

    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp parse_role(%{"role" => role}), do: role_atom(role)
  defp parse_role(_params), do: {:error, {:missing_field, "role"}}

  defp role_atom("admin"), do: {:ok, :admin}
  defp role_atom("editor"), do: {:ok, :editor}
  defp role_atom("member"), do: {:ok, :member}
  defp role_atom(_other), do: {:error, {:invalid_field, "role"}}

  # The provider lowercases addresses before its uniqueness check, so match it here
  defp parse_email(%{"email" => email}) when is_binary(email), do: {:ok, String.downcase(email)}
  defp parse_email(%{"email" => _email}), do: {:error, {:invalid_field, "email"}}
  defp parse_email(_params), do: {:error, {:missing_field, "email"}}

  defp parse_age(%{"age" => age}) when is_integer(age), do: {:ok, min(age, @max_age)}

  defp parse_age(%{"age" => age}) when is_binary(age) do
    case Integer.parse(age) do
      {age, ""} ->
        {:ok, min(age, @max_age)}

      {_age, _rest} ->
        {:error, {:invalid_field, "age"}}

      :error ->
        {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(%{"age" => _age}), do: {:error, {:invalid_field, "age"}}
  defp parse_age(_params), do: {:error, {:missing_field, "age"}}

  defp send_welcome(user) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

## Changeset this code relies on (in `Accounts.User`)

```elixir
def changeset(user, attrs) do
  user
  |> cast(attrs, [:email, :age, :role, :nickname])
  |> validate_required([:email, :age, :role, :nickname])
  |> validate_number(:age, greater_than_or_equal_to: 18)
  |> unique_constraint(:email)
end
```

`role` should be an `Ecto.Enum` field. A matching unique index on `email` is required for `unique_constraint/3` to work.
