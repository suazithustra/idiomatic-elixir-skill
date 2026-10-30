# Review of `Accounts.UserImporter`

I assumed `Accounts.User` has `User.changeset/2` (casting `email`, `age`, `role`, `nickname`, with `validate_number(:age, greater_than_or_equal_to: 18)` and `unique_constraint(:email)`), a `:name` field, and that `Accounts.Mailer` and an `Accounts.TaskSupervisor` exist. I did not have those modules. The role list (`admin`, `editor`, `member`) is a placeholder. Replace it with the real roles.

## Findings

1. **Atom exhaustion from user input.** Rule: "Convert external strings to atoms with explicit clauses". `role = String.to_atom(params["role"])` lets anyone who controls the input fill the VM's atom table. It also raises on a missing role. Fix: `parse_role/1` with one clause per accepted role and an `{:error, {:invalid_field, "role"}}` catch-all.

2. **`try/rescue _ ->` hides every bug.** Rule: "Return `{:ok, value}` or `{:error, reason}` for expected failures". `rescue _ -> {:error, :invalid}` turns a `nil` email, a bad age and a database crash into the same `:invalid`. Fix: remove the `try`. Use `Integer.parse/1` instead of `String.to_integer/1`, and match the required keys in the function head.

3. **`age = 120` inside `if` has no effect.** Rule: "Assign the result of `if`, `case`, and `Enum` calls". The rebinding stays inside the block, so ages over 120 are never capped, and the compiler warns about an unused variable. Fix: `min(age, @max_age)` in `parse_age/1`, with `@max_age` as a named attribute.

4. **Required keys read with `params["email"]`.** Rule: "Match the required keys of string-keyed input in a function head". `params["email"] |> String.downcase()` raises on a missing key, and `is_binary(email)` is checked after `String.downcase` has already run on it. Fix: match `"email"`, `"age"` and `"role"` in the head with `when is_binary(email)`, and add `def import_user(_params, _opts), do: {:error, :invalid_params}` as the catch-all.

5. **Struct built from params and inserted without a changeset.** Rule (ecto-phoenix): "Validate input with changesets". `Repo.insert(%User{...})` validates nothing. Fix: `User.changeset/2`, then `Repo.insert/1`.

6. **Lookup before insert for uniqueness.** `Repo.get_by(User, email: email) == nil` is a race: two imports can both pass the check, and one insert then raises. Rule: `unique_constraint/3` in the changeset. Fix: declare it there so a duplicate returns `{:error, changeset}`.

7. **`_ ->` clause after `{:ok, user}`.** Rule: "Match every expected shape". `_ -> {:error, :insert_failed}` throws away the changeset errors. Fix: `Repo.insert/1` returns `{:error, changeset}` and `with` passes it through.

8. **Deeply nested `try`, `if`, `case`, `if`.** Rule: "Keep functions short and at one level of detail", and `with` for chained steps. Fix: `with` over `parse_role/1`, `parse_age/1` and `insert_user/4`, each returning `{:ok, value}` or `{:error, reason}`.

9. **`&&` and `!` on booleans.** Rule: "Use `and`, `or`, `not` when the operands are booleans". This applies to `is_binary(email) && age >= 18` and `opts[:notify] && !opts[:silent]`. The first check disappears into the head guard and the changeset.

10. **Overlapping boolean options and an option that changes the return shape.** Rules: "Use one atom-valued field or option instead of overlapping booleans" and "Give each function one return shape". `notify: true, silent: true` is contradictory, and `return_id: true` makes the function return an integer instead of `{:ok, user}`. Fix: keep only `:notify`, validated with `Keyword.validate!/2` and documented under `## Options`. Callers who want the id read `user.id`. **This changes the public API.** Callers that pass `silent:` or `return_id:` must be updated.

11. **Bare `spawn/1`.** Rule (processes): "Supervise every long-lived process". An unsupervised process whose crash goes unnoticed and whose closure copies the whole `user`. Fix: `Task.Supervisor.start_child(Accounts.TaskSupervisor, ...)`, with the email built before the closure so only that is copied. `Accounts.TaskSupervisor` must be added to the application's supervision tree.

12. **`user[:name]` on a struct.** Rule: "Read required keys with `map.key`". Structs do not implement `Access`, so this raises `UndefinedFunctionError`. Fix: `user.name || "there"`.

13. **Piping into an anonymous function.** Rule: "Do not pipe into an anonymous function call". `greeting |> (fn text -> ... end).()` is a single string. Fix: build it with interpolation.

14. **Comments that restate code, and no docs.** Deleted `# Get the role from params`, `# send the email` and the other comments that restate the code. Kept the one that gives a reason (the provider lowercases addresses). Added `@moduledoc` and `@doc`.

15. **Alias order and unaliased `Mailer`.** `alias Accounts.{Repo, User}` is now one alias per line, after `@moduledoc`. `Mailer` is aliased as `Accounts.Mailer`. Fix this if the real module lives elsewhere.

## Behaviour changes

- The error values change: `:invalid` and `:insert_failed` become `{:error, {:invalid_field, key}}`, `{:error, :invalid_params}` or `{:error, changeset}`.
- An age under 18 now fails in the changeset instead of in the importer, so the changeset must enforce it.
- Existing callers that match on the old error atoms must be updated.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from external CSV/JSON params.
  """

  alias Accounts.Mailer
  alias Accounts.Repo
  alias Accounts.User

  @max_age 120

  @doc """
  Imports a single user from string-keyed params.

  Requires the `"email"`, `"age"` and `"role"` keys; `"nickname"` is optional
  and defaults to the email. Ages above 120 are capped at 120. The remaining
  checks (minimum age, unique email) live in `User.changeset/2`.

  Returns `{:ok, user}`, `{:error, changeset}` when validation or a database
  constraint fails, `{:error, {:invalid_field, key}}` for an unparseable `"age"`
  or `"role"`, or `{:error, :invalid_params}` when a required key is missing.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ [])

  def import_user(%{"email" => email, "age" => age, "role" => role} = params, opts)
      when is_binary(email) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, role} <- parse_role(role),
         {:ok, age} <- parse_age(age),
         {:ok, user} <- insert_user(params, email, age, role) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  def import_user(_params, _opts), do: {:error, :invalid_params}

  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("editor"), do: {:ok, :editor}
  defp parse_role("member"), do: {:ok, :member}
  defp parse_role(_other), do: {:error, {:invalid_field, "role"}}

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {age, ""} -> parse_age(age)
      {_age, _rest} -> {:error, {:invalid_field, "age"}}
      :error -> {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(age) when is_integer(age), do: {:ok, min(age, @max_age)}
  defp parse_age(_age), do: {:error, {:invalid_field, "age"}}

  defp insert_user(params, email, age, role) do
    # The provider lowercases addresses before its uniqueness check, so match it here
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

  defp send_welcome(user) do
    welcome_email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(welcome_email) end)
  end

  defp welcome_email(user) do
    name = user.name || "there"
    "Hi #{name}, welcome! Enjoy your account."
  end
end
```

## Not verified

I could not write a scratch copy outside the project directory, so I did not run `mix format --check-formatted` or compile the improved code. It also depends on the assumed `User`, `Mailer` and `TaskSupervisor` modules above. Run `mix format` and `mix compile` before using it.
