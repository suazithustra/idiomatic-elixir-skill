# Review: `Accounts.UserImporter`

## Findings

1. **The age cap never applies.** Line 15 rebinds `age` inside an `if`, and the new value does not leave the block, so a 150-year-old is stored as 150. Clamp with `min(age, @max_age)` instead (rule "Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it", `SKILL.md`).

2. **Atoms are created from input.** Line 8, `String.to_atom(params["role"])`, lets any caller grow the atom table until the node crashes. Declare the role as an `Ecto.Enum` field on the schema and cast it in the changeset, so no atom is created from input (rule "Convert external strings to atoms with explicit clauses", `SKILL.md`).

3. **A catch-all rescue hides bugs.** Lines 38-39, `rescue _ -> {:error, :invalid}`, wrap the whole function, so a failed database write, a bad mailer call, or a typo all return the same error as bad input. Remove the `try` and use non-raising calls: `Integer.parse/1` instead of `String.to_integer/1`, and an explicit `case` on `Repo.insert/1` (rule "Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs", `SKILL.md`).

4. **Structs are built from raw params, skipping validation.** Line 22, `%User{email: email, age: age, role: role, nickname: nickname}` goes straight to `Repo.insert/1`, so nothing is validated and a duplicate email raises. Build the struct through a changeset and add `unique_constraint(:email)` so a duplicate returns `{:error, changeset}` (rule "Validate input with changesets", `references/ecto-phoenix.md`).

5. **The insert error is discarded.** Line 32, `_ -> {:error, :insert_failed}`, drops the changeset that explains the failure. Match `{:error, changeset}` and return it inside the error tuple (rule "Match every expected shape and let unexpected ones crash", `SKILL.md`).

6. **The `:return_id` option changes the return type.** Line 30 returns a bare integer when `return_id` is set and `{:ok, user}` otherwise. Make `import_user/2` always return `{:ok, user}` and add `import_user_id/2` that returns `{:ok, id}` (rule "Give each function one return shape", `SKILL.md`).

7. **Overlapping booleans.** Lines 26 and 30 use `notify` and `silent` together, so `notify: true, silent: true` has a meaning that is not documented. Remove `silent` (rule "Use one atom-valued field or option instead of overlapping booleans", `SKILL.md`). Callers that pass `silent:` will now get an error from `Keyword.validate!/2`.

8. **Options are not validated.** Line 6 takes `opts \\ []` and never checks it, so a misspelled option is ignored. Validate with `Keyword.validate!/2` and document the options under `## Options` in `@doc` (rule "Group related parameters", `SKILL.md`).

9. **`spawn/1` is unsupervised and copies the whole user.** Line 45 starts a bare process that the supervisor cannot see, and the closure captures the whole `user`. Start it under a `Task.Supervisor` and capture only the email text (rule "Supervise every long-lived process" and "Send processes only the data they need", `references/processes.md`).

10. **Access syntax on a struct.** Line 49, `user[:name]`, raises `UndefinedFunctionError` because structs do not implement `Access`. Use `user.name` (rule "Read required keys with `map.key` or a pattern; keep `map[:key]` for optional keys", `SKILL.md`).

11. **Magic numbers.** The literals `120` (line 15) and `18` (line 21) carry no name. Define `@max_age` and `@min_age` (rule "Name magic numbers with module attributes", `SKILL.md`).

12. **Pipe into an anonymous function.** Line 51, `greeting |> (fn text -> ... end).()`, is a pipe into an anonymous function call. Build the string in one step (rule "Write pipelines that start with a value and read top to bottom", `SKILL.md`).

13. **Single-step pipe and `&&` on booleans.** Line 12, `params["email"] |> String.downcase()`, pipes one step. Line 21, `is_binary(email) && age >= 18`, joins two booleans with `&&` where `and` is meant. Line 21 also checks `is_binary(email)` after `String.downcase/1` has already run, so the check is redundant (rules "Do not pipe a single step" and "Use `and`, `or`, `not` when the operands are booleans", `SKILL.md`).

14. **Documentation is in comments.** Lines 2 and 5 describe the module and the function in comments. Move them to `@moduledoc` and `@doc`. Lines 7 and 44 restate the code and should be deleted (rule "Comments explain why; documentation goes in `@moduledoc` and `@doc`", `SKILL.md`). Line 11 explains why the email is lowercased, so it stays.

15. **Input is read key by key.** Lines 6-13 read `params["..."]` and convert each value without checking it, so a missing or malformed field fails with a generic error. Check each field in a small function that returns `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}`, and chain them with `with` (rule "Parse external data into structs where it enters the system", `SKILL.md`, and "Match every expected shape", `SKILL.md`).

## Assumptions in the improved code

The input file refers to modules that are not in it. The improved code assumes the following. Check each one.

- `Accounts.User` has an `import_changeset/2` function. It casts `:email`, `:age`, `:role`, and `:nickname`, requires `:email`, `:age`, and `:role`, and calls `unique_constraint(:email)`. Suggested body:

  ```elixir
  def import_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :age, :role, :nickname])
    |> validate_required([:email, :age, :role])
    |> unique_constraint(:email)
  end
  ```

- The `role` field is declared as `Ecto.Enum` with the valid values, so unknown roles fail in the changeset.
- `Accounts.User` has a `name` field. The original read `name` from the struct, so this is kept.
- `Accounts.TaskSupervisor` is a `Task.Supervisor` in the application's supervision tree.
- Callers that passed `silent:` or `return_id:` must be updated to match the new options.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV (comma-separated values) or JSON source.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from the given params.

  Returns `{:ok, user}` or `{:error, reason}`.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    [notify: notify] = Keyword.validate!(opts, notify: false)

    with {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         :ok <- check_adult(age),
         {:ok, user} <- insert_user(params, email, age) do
      if notify, do: send_welcome(user)
      {:ok, user}
    end
  end

  @doc """
  Imports a single user and returns its ID.

  Takes the same options as `import_user/2`.
  """
  def import_user_id(params, opts \\ []) do
    case import_user(params, opts) do
      {:ok, user} -> {:ok, user.id}
      {:error, _reason} = error -> error
    end
  end

  defp parse_email(nil), do: {:error, {:missing_field, "email"}}
  defp parse_email(email) when is_binary(email), do: {:ok, String.downcase(email)}
  defp parse_email(_email), do: {:error, {:invalid_field, "email"}}

  defp parse_age(nil), do: {:error, {:missing_field, "age"}}

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {value, ""} -> {:ok, min(value, @max_age)}
      _ -> {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(_age), do: {:error, {:invalid_field, "age"}}

  defp check_adult(age) when age >= @min_age, do: :ok
  defp check_adult(_age), do: {:error, {:invalid_field, "age"}}

  defp insert_user(params, email, age) do
    attrs = %{
      "email" => email,
      "age" => age,
      "role" => params["role"],
      "nickname" => params["nickname"] || email
    }

    case Repo.insert(User.import_changeset(%User{}, attrs)) do
      {:ok, user} -> {:ok, user}
      {:error, changeset} -> {:error, {:insert_failed, changeset}}
    end
  end

  defp send_welcome(user) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user) do
    name = user.name || "there"
    "Hi #{name}, welcome! Enjoy your account."
  end
end
```
