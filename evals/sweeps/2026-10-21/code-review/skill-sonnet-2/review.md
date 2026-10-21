# Review: `Accounts.UserImporter`

## Findings

1. **Atom exhaustion** (rule: convert external strings to atoms with explicit clauses). `role = String.to_atom(params["role"])` lets anyone who controls the input create atoms until the VM crashes. A missing role also raises. Fix: `parse_role/1` with one clause per accepted role and an error clause.

2. **`try/rescue _ ->` around the whole function** (rule: return tuples for expected failures; never `rescue _`). `rescue _ -> {:error, :invalid}` hides real bugs, such as a `Repo` crash or a typo, behind `:invalid`. Fix: remove it. Use `Integer.parse/1` instead of `String.to_integer/1`, and match the input shape.

3. **Rebinding inside `if` does not escape** (rule: assign the result of `if`). `if age > 120 do age = 120 end` leaves `age` unchanged, and the compiler warns that the inner `age` is unused. Fix: `min(age, @max_age)`.

4. **`&&` and `!` on booleans** (rule: use `and`, `or`, `not`). `is_binary(email) && age >= 18` and `opts[:notify] && !opts[:silent]`. The `is_binary(email)` check also comes after `String.downcase/1` has already raised for a non-string. Fix: validate the email before downcasing, and use `and`/`not` where operands are booleans.

5. **Overlapping booleans** (rule: one atom-valued field instead of overlapping booleans). `notify: true, silent: true` is contradictory. Fix: keep only `:notify`, and check options with `Keyword.validate!/2`.

6. **Option changes the return shape** (rule: one return shape). `if opts[:return_id], do: user.id, else: {:ok, user}` returns either an id or a tuple. Fix: remove `:return_id`. Callers read `user.id` from `{:ok, user}`. This changes the public API; check callers first.

7. **Catch-all `_ ->` on `Repo.insert/1`** (rule: match every expected shape). The changeset error is thrown away as `:insert_failed`. Fix: match `{:error, changeset}` and return `{:error, {:insert_failed, changeset}}`.

8. **Reading a struct with `[:name]`** (rule: `map.key` for required keys; structs do not implement `Access`). `user[:name]` raises `UndefinedFunctionError` on `%User{}`. Fix: `user.nickname`. The struct as built here has no `:name` field, so the greeting now uses the nickname. Change it back to `user.name` if `User` has that field.

9. **Unsupervised `spawn/1` that captures the whole `user`** (processes.md: supervise processes; send processes only the data they need). A crash in `Mailer.deliver/1` is invisible, and the closure copies the whole struct. Fix: build the email in the caller, then `Task.Supervisor.start_child/2` with only that email. This assumes `Accounts.TaskSupervisor` is started in the application's supervision tree. Add `{Task.Supervisor, name: Accounts.TaskSupervisor}` to the children if it is not.

10. **Pipeline into an anonymous function** (rule: pipelines). `greeting |> (fn text -> ... end).()` is a single-step pipe into a lambda. Fix: build the string once with interpolation.

11. **Invalid input collapses to `{:error, :invalid}`** (rule: parse external data at the boundary; report the field). Callers cannot tell a bad age from a missing email. Fix: check each field in a small function chained with `with`, returning `{:missing_field, key}` or `{:invalid_field, key}`. Underage users get `{:error, {:invalid_field, "age"}}`.

12. **Long, mixed-level function** (rule: short functions at one level of detail). `import_user/2` parses, validates, inserts, and notifies, with `if` inside `case` inside `if`. Fix: split into `with` steps and private helpers.

13. **Comments and docs** (rule: comments explain why; docs in `@moduledoc`/`@doc`). Delete `# Get the role from params`, `# send the email`, and the other comments that restate the code. Replace `# Import a single user...` and the module comment with `@moduledoc`/`@doc` and a `@spec`. The comment about the provider lowercasing addresses explains a reason, so it stays. Name the magic numbers `18` and `120` with module attributes.

Assumptions: the accepted roles (`admin`, `editor`, `member`) are placeholders. Replace them with the real `User` roles. I did not compile this, so check it with `mix compile` and `mix format`.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from string-keyed params produced by the external CSV/JSON source.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from string-keyed `params`.

  Requires `"email"`, `"age"`, and `"role"`. `"nickname"` is optional and
  defaults to the email. Ages above #{@max_age} are stored as #{@max_age}.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.

  ## Errors

    * `{:error, {:missing_field, key}}`
    * `{:error, {:invalid_field, key}}`
    * `{:error, {:unknown_role, role}}`
    * `{:error, {:insert_failed, changeset}}`
  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, term()}
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, email} <- fetch_email(params),
         {:ok, age} <- fetch_age(params),
         {:ok, role} <- fetch_role(params),
         user = %User{
           email: email,
           age: age,
           role: role,
           nickname: params["nickname"] || email
         },
         {:ok, user} <- insert_user(user) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  defp fetch_email(%{"email" => email}) when is_binary(email) do
    # The provider lowercases addresses before its uniqueness check, so match it here
    {:ok, String.downcase(email)}
  end

  defp fetch_email(%{"email" => _email}), do: {:error, {:invalid_field, "email"}}
  defp fetch_email(_params), do: {:error, {:missing_field, "email"}}

  defp fetch_age(%{"age" => age}) when is_binary(age) do
    case Integer.parse(age) do
      {age, ""} -> validate_age(age)
      {_age, _rest} -> {:error, {:invalid_field, "age"}}
      :error -> {:error, {:invalid_field, "age"}}
    end
  end

  defp fetch_age(%{"age" => _age}), do: {:error, {:invalid_field, "age"}}
  defp fetch_age(_params), do: {:error, {:missing_field, "age"}}

  defp validate_age(age) when age >= @min_age, do: {:ok, min(age, @max_age)}
  defp validate_age(_age), do: {:error, {:invalid_field, "age"}}

  defp fetch_role(%{"role" => role}), do: parse_role(role)
  defp fetch_role(_params), do: {:error, {:missing_field, "role"}}

  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("editor"), do: {:ok, :editor}
  defp parse_role("member"), do: {:ok, :member}
  defp parse_role(other), do: {:error, {:unknown_role, other}}

  defp insert_user(user) do
    case Repo.insert(user) do
      {:ok, user} -> {:ok, user}
      {:error, changeset} -> {:error, {:insert_failed, changeset}}
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
