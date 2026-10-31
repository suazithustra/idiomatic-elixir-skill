# Review: `Accounts.UserImporter`

## Findings

1. **The age cap never applies.** Line 15-17: `if age > 120 do age = 120 end`. Rebinding inside `if` does not change the outer `age`, so users over 120 are saved with their original age. Rule (SKILL.md, "Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it"). Fix: `min(value, @max_age)` in `parse_age/1`.

2. **The welcome email never sends.** Line 53: `name = user[:name] || "there"`. `user` is a `%User{}` struct, and structs do not implement `Access`, so this raises `UndefinedFunctionError`. The raise happens inside the `spawn/1` closure, so nothing reports it. Rule (SKILL.md, "Read required keys with `map.key` or a pattern; keep `map[:key]` for optional keys"). Fix: read `user.nickname`, which is always set because it falls back to the email.

3. **User input creates atoms.** Line 8: `role = String.to_atom(params["role"])`. Anyone who controls the input can fill the atom table, and a `nil` role raises. Rule (SKILL.md, "Convert external strings to atoms with explicit clauses"). Fix: declare `role` as an `Ecto.Enum` field and let `cast/3` accept only its listed values.

4. **A `rescue` catches every error in the function.** Lines 10 and 42-43: `rescue _ -> {:error, :invalid}` turns database outages and bugs into "invalid input". Rule (SKILL.md, "Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs"): rescue specific exceptions only, never `rescue _ ->`. Fix: remove the `try`. Every failure path now returns a tuple.

5. **`String.to_integer/1` raises on bad input.** Line 13: `age = String.to_integer(params["age"])`. Bad input is an expected failure, so it should not raise and then get rescued. Rule (SKILL.md, the same section as finding 4: "Call the non-raising version instead"). Fix: `Integer.parse/1`, with a clause for each result.

6. **Duplicate check is a lookup followed by an insert.** Lines 24-25: `if Repo.get_by(User, email: email) == nil do` then `Repo.insert(user)`. Two requests with the same email can both pass the check. Rule (references/ecto-phoenix.md, "Validate input with changesets"): declare the constraint with `unique_constraint/3`, so the database decides and a violation returns `{:error, changeset}`. Fix: `unique_constraint(:email)` in `User.changeset/2`, and no lookup.

7. **The struct is inserted without a changeset.** Line 22 and 25: `user = %User{email: email, age: age, role: role, nickname: nickname}` then `Repo.insert(user)`. Nothing is validated, and a constraint violation raises. Rule (references/ecto-phoenix.md, "Validate input with changesets"). Fix: `%User{} |> User.changeset(attrs) |> Repo.insert()`.

8. **The return shape depends on an option.** Line 31: `if opts[:return_id], do: user.id, else: {:ok, user}`. With `return_id: true` the caller gets a bare integer, otherwise a tuple. Rule (SKILL.md, "Give each function one return shape"). Fix: remove `:return_id`. Callers read `user.id` from `{:ok, user}`.

9. **A catch-all clause hides the error reason.** Line 33: `_ -> {:error, :insert_failed}`. Any new return value becomes the same error, and the changeset that explains the failure is dropped. Rule (SKILL.md, "Match every expected shape and let unexpected ones crash"). Fix: `Repo.insert/1` returns only `{:ok, user}` or `{:error, changeset}`, so `with` passes the error through.

10. **Different failures share one reason.** Lines 37 and 40: both a duplicate email and an age under 18 return `{:error, :invalid}`. Rule (SKILL.md, "Match every expected shape and let unexpected ones crash": "Different failures need different reasons too"). Fix: `{:missing_field, key}` and `{:invalid_field, key}` from small functions, one per field.

11. **String-keyed input is read by key and checked later.** Lines 12-21: `params["email"]`, `params["age"]`, and `params["nickname"] || email` are read in the body. Rule (SKILL.md, "Parse external data into structs where it enters the system"): match the required keys in a function head, and give the no-match case its own clause. Fix: `fetch_email/1` and `parse_age/1` match `"email"` and `"age"` in their heads.

12. **Nested `if` chain and a long function.** Lines 15-41 nest four conditions deep in one 40-line function. Rule (SKILL.md, "Branch with function clauses and guards before reaching for `if` or `cond`") and (SKILL.md, "Keep functions short and at one level of detail"). Fix: a `with` over `parse_params/1` and `insert_user/1`, each a small private function.

13. **`&&` joins two booleans.** Line 21: `if is_binary(email) && age >= 18 do`. Both operands are booleans, so `and` is the right operator and it checks that. Rule (SKILL.md, "Use `and`, `or`, `not` when the operands are booleans"). Fix: the checks move into function clauses, so no `&&` remains. The `is_binary/1` check on line 21 also runs after `String.downcase/1`, which already raises on a non-string. The new `fetch_email/1` checks the type first.

14. **Two booleans overlap.** Line 27: `if opts[:notify] && !opts[:silent] do`. `silent` only has an effect when `notify` is also set, and `notify: true, silent: true` is a combination that should not exist. Rule (SKILL.md, "Use one atom-valued field or option instead of overlapping booleans"). Fix: drop `:silent`. Callers that passed `silent: true` and got no email still get none, because they stop passing `notify: true`.

15. **Options are not checked.** Line 6: `def import_user(params, opts \\ [])` accepts any keyword list, and the options are not documented. Rule (SKILL.md, "Group related parameters": "check them with `Keyword.validate!/2`, and document each one under `## Options` in `@doc`"). Fix: `Keyword.validate!(opts, notify: false)` and an `## Options` section in `@doc`. Unknown options now raise.

16. **A bare `spawn/1` runs outside any supervisor.** Line 49: `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`. A crash is lost, and the process is not visible to supervision tools. Rule (references/processes.md, "Supervise every long-lived process"). Fix: `Task.Supervisor.start_child/2` under a named `Accounts.TaskSupervisor`.

17. **A pipe goes into an anonymous function.** Line 55: `greeting |> (fn text -> text <> " Enjoy your account." end).()`. Rule (SKILL.md, "Do not pipe into an anonymous function call"). Fix: build the whole text in one string.

18. **A single step is piped.** Line 12: `params["email"] |> String.downcase()`. Rule (SKILL.md, "Do not pipe a single step"). Fix: `String.downcase(email)`, inside `fetch_email/1`.

19. **Comments restate the code or hold documentation.** Lines 2, 5, 7 and 48: `# This module imports users...`, `# Import a single user from the given params`, `# Get the role from params`, `# send the email`. Rule (SKILL.md, "Comments explain why; documentation goes in `@moduledoc` and `@doc`"). Fix: move the module and function descriptions to `@moduledoc` and `@doc`, delete the restating comments, and keep the one comment that gives a reason (line 11, about lowercasing).

## Improved version

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV (comma-separated values) or JSON (JavaScript Object Notation) source.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports one user from string-keyed `params`.

  Returns `{:ok, user}`. Returns `{:error, {:missing_field, key}}` or
  `{:error, {:invalid_field, key}}` when the input is wrong, and
  `{:error, changeset}` when the database rejects the row, such as a duplicate email.

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

  defp parse_params(params) do
    with {:ok, email} <- fetch_email(params),
         {:ok, age} <- parse_age(params) do
      attrs = %{
        email: email,
        age: age,
        role: params["role"],
        nickname: params["nickname"] || email
      }

      {:ok, attrs}
    end
  end

  # The provider lowercases addresses before its uniqueness check, so match it here
  defp fetch_email(%{"email" => email}) when is_binary(email),
    do: {:ok, String.downcase(email)}

  defp fetch_email(%{"email" => _email}), do: {:error, {:invalid_field, "email"}}
  defp fetch_email(_params), do: {:error, {:missing_field, "email"}}

  defp parse_age(%{"age" => age}) when is_binary(age) do
    case Integer.parse(age) do
      {value, ""} when value >= @min_age ->
        {:ok, min(value, @max_age)}

      {_value, _rest} ->
        {:error, {:invalid_field, "age"}}

      :error ->
        {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(%{"age" => _age}), do: {:error, {:invalid_field, "age"}}
  defp parse_age(_params), do: {:error, {:missing_field, "age"}}

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

## Assumptions and behavior changes

- `User.changeset/2` does not appear in the input. It must cast `:email`, `:age`, `:role` and `:nickname`, declare `role` as `Ecto.Enum` with the roles the app uses, validate the required fields, and call `unique_constraint(:email)`. The database needs a unique index on `email`. A minimal version:

  ```elixir
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :age, :role, :nickname])
    |> validate_required([:email, :age, :role])
    |> unique_constraint(:email)
  end
  ```

- `Accounts.TaskSupervisor` must be started in the application's supervision tree, for example `{Task.Supervisor, name: Accounts.TaskSupervisor}`.
- The `User` struct is assumed to have a `nickname` field, as the input uses. The input's `user[:name]` suggested a `name` field, but the struct the input builds has none.
- Callers that passed `return_id` or `silent` now get an error, because `Keyword.validate!/2` rejects unknown options.
- A duplicate email now returns `{:error, changeset}` instead of `{:error, :invalid}`.
- The welcome greeting uses the nickname. The input's version never produced a greeting, so no previous output exists to match.
- Ages over 120 are saved as 120, which is what the input's clamp intended.
