# Review: `Accounts.UserImporter`

Input: `code-review-input.ex`. Rules applied from `SKILL.md`, plus `references/ecto-phoenix.md` (Repo) and `references/processes.md` (spawn).

## Findings

1. **Convert external strings to atoms with explicit clauses.** `role = String.to_atom(params["role"])` (line 8). Atoms are never collected, so any caller can exhaust the atom table. A missing role also raises outside the `try`. Replaced with `parse_role/1` clauses for the accepted roles.

2. **Never wrap a whole function in `rescue _ ->`.** `rescue _ -> {:error, :invalid}` (lines 38-40) hides every bug, including a typo in the module. Removed. Failures are now returned as tuples.

3. **Call the non-raising version instead of rescuing.** `String.to_integer(params["age"])` (line 13) raises on bad input. Replaced with `Integer.parse/1` in `parse_age/1`.

4. **Rebinding inside `if` does not escape the block.** `if age > 120 do age = 120 end` (lines 15-17) leaves `age` unchanged, and the compiler warns. Replaced with `min(age, @max_age)`.

5. **Use `and` for boolean operands, or avoid the operator.** `is_binary(email) && age >= 18` (line 21). The check is replaced by the `with` chain in `parse_attrs/1` and `parse_age/1`, so no boolean operator remains.

6. **Pipe-to-one-call and pipe into anonymous function.** `params["email"] |> String.downcase()` (line 12) is a single step. `greeting |> (fn text -> ... end).()` (line 51) is the forbidden form. Both removed.

7. **Use `with` for a chain of fallible steps, one private function per step.** The nested `if`/`case` (lines 15-37) becomes a three-step `with`: `parse_role/1`, `parse_attrs/1`, `insert_user/2`.

8. **Validate external data through a changeset, not `Repo.insert(%User{...})`.** `Repo.insert(user)` (line 24) inserts the struct unchecked, so nothing is validated and a duplicate email raises. Replaced with `User.changeset/2` and `Repo.insert/1`. The role is set on the struct before `cast/3`, so input cannot choose it. This assumes `User.changeset/2` casts `email`, `age`, and `nickname`, and calls `unique_constraint(:email)`.

9. **Match the error shape; do not collapse it.** `_ -> {:error, :insert_failed}` (line 32) discards the changeset. The `{:error, changeset}` from `Repo.insert/1` now passes through.

10. **One return shape per function.** `if opts[:return_id], do: user.id, else: {:ok, user}` (line 30) makes `import_user/2` return an integer or a tuple. Removed. Callers that need the ID read `user.id` from `{:ok, user}`. This is a breaking change for callers that pass `return_id: true`.

11. **Overlapping booleans.** `opts[:notify] && !opts[:silent]` (line 26) combines two booleans where `notify: true, silent: true` makes no sense. Replaced with one atom option, `notify: :welcome | :none`, default `:none`. This is a breaking change for callers that pass `silent:`.

12. **Validate keyword options.** `opts` is never checked (line 6). Added `Keyword.validate!(opts, notify: :none)`, so a misspelled option raises at the call site. Documented under `## Options` in `@doc`.

13. **Name magic numbers with module attributes.** `18` and `120` (lines 15, 21) become `@min_age` and `@max_age`.

14. **Do not spawn unsupervised processes.** `spawn(fn -> Mailer.deliver(welcome_email(user)) end)` (line 45) is outside any supervisor, so a crash is invisible and the process is not in the tree. Replaced with `Task.Supervisor.start_child/2`. The email string is computed in the caller, so the closure captures a string and not the whole `user`. This assumes an `Accounts.TaskSupervisor` is in the application's supervision tree.

15. **Structs do not implement Access.** `user[:name]` (line 49) raises `UndefinedFunctionError`, and `User` has no `name` field here anyway. The greeting now uses `user.nickname`, which `import_user` always sets (it defaults to the email), so the `"there"` fallback is gone.

16. **Comments that restate code.** `# Get the role from params` (line 7) and `# send the email` (line 44) restate the code. Deleted. `# Import a single user from the given params` (line 5) becomes the `@doc`. The module comment (line 2) becomes `@moduledoc`. The comment on line 11 explains a reason the code cannot show, so it stays.

17. **Errors name the field.** Missing or malformed input now returns `{:error, {:invalid_field, key}}` (previously `{:error, :invalid}` for every case), so a caller can tell which field failed.

## Assumptions to check

- Roles are `:member`, `:editor`, and `:admin`. `parse_role/1` must list the real roles.
- `User.changeset/2` exists and includes `unique_constraint(:email)`.
- `Accounts.TaskSupervisor` is started by the application. `Mailer.deliver/1` accepts the value `welcome_email/1` returns, as the original code assumed.
- The age cap at 120 is kept from the original. Silently capping an age is a business decision worth confirming.

## Improved version

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

  Returns `{:ok, user}`, `{:error, {:invalid_field, field}}` for a missing or
  malformed field, or `{:error, changeset}` when validation or a database
  constraint rejects the user.

  ## Options

    * `:notify` - `:welcome` sends a welcome email after the insert, `:none`
      sends nothing. Defaults to `:none`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: :none)

    with {:ok, role} <- parse_role(params["role"]),
         {:ok, attrs} <- parse_attrs(params),
         {:ok, user} <- insert_user(role, attrs) do
      maybe_send_welcome(user, opts[:notify])
      {:ok, user}
    end
  end

  defp parse_role("member"), do: {:ok, :member}
  defp parse_role("editor"), do: {:ok, :editor}
  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role(_other), do: {:error, {:invalid_field, "role"}}

  defp parse_attrs(params) do
    with {:ok, email} <- string_field(params, "email"),
         {:ok, age} <- parse_age(params["age"]) do
      # The provider lowercases addresses before its uniqueness check, so match it here
      email = String.downcase(email)
      {:ok, %{email: email, age: age, nickname: params["nickname"] || email}}
    end
  end

  defp string_field(params, key) do
    case params[key] do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp parse_age(text) when is_binary(text) do
    case Integer.parse(text) do
      {age, ""} when age >= @min_age -> {:ok, min(age, @max_age)}
      _ -> {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(_text), do: {:error, {:invalid_field, "age"}}

  defp insert_user(role, attrs) do
    %User{role: role}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp maybe_send_welcome(user, :welcome) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp maybe_send_welcome(_user, :none), do: :ok

  defp welcome_email(user), do: "Hi #{user.nickname}, welcome! Enjoy your account."
end
```
