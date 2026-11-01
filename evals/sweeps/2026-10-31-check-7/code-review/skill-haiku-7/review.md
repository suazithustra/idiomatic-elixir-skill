# Review: `Accounts.UserImporter`

Source: `code-review-input.ex`. Rules are cited by heading in `idiomatic-elixir/SKILL.md` unless marked as coming from `references/ecto-phoenix.md` or `references/processes.md`.

## Findings

Most severe first.

1. **The welcome email is never sent.** `welcome_email/1` reads `user[:name]` (line 53). `user` is a `%User{}` struct, and structs do not support bracket access, so the spawned process crashes with `UndefinedFunctionError`. Fix: use `user.nickname`, which the import already sets on line 19. The `"there"` fallback goes, because nickname is never empty. (Rule: Read required keys with `map.key` or a pattern; keep `map[:key]` for optional keys.)

2. **The age cap never applies.** In `if age > 120 do age = 120 end` (lines 15-17), the new value exists only inside the `if`. The outer `age` keeps the parsed value, so 150 stays 150. Fix: `age: min(age, @max_age)`. (Rule: Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it.)

3. **Role strings become atoms.** `String.to_atom(params["role"])` (line 8) creates a new atom for each distinct input. Atoms are never freed, so enough distinct roles can exhaust the atom table (the VM's fixed list of names) and crash the node. The call also sits outside the `try`, so a missing role raises there. Fix: pass the role string to the changeset and declare the field as `Ecto.Enum` (Ecto's enum type) in `User`, which accepts only the listed values. (Rule: Convert external strings to atoms with explicit clauses.)

4. **A blanket `rescue` hides failures.** `rescue _ -> {:error, :invalid}` (lines 42-43) turns every exception, including database connection errors and plain bugs, into one reply. Fix: remove the `try`. Expected failures return tuples; unexpected exceptions crash where they occur. (Rule: Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs.)

5. **Raising parsers run inside the `try`.** `String.to_integer(params["age"])` (line 13) raises on `"abc"` and on a missing key. `String.downcase/1` raises on `nil`. Fix: parse with `Integer.parse/1` in `parse_integer/2`, and check each field in `string_field/2`, which returns `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}`. (Rule: Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs.)

6. **The insert skips validation.** `Repo.insert(user)` on a `%User{...}` struct (line 22) writes the struct as given, so no field is checked. Fix: `%User{} |> User.changeset(attrs) |> Repo.insert()`. This assumes `User.changeset/2` exists. The module was not provided, so check it. (Rule, in `references/ecto-phoenix.md`: Validate input with changesets.)

7. **A duplicate check runs before the insert.** `if Repo.get_by(User, email: email) == nil do` (line 24) costs an extra query, and a second process can insert the same email between the check and the insert. Fix: declare `unique_constraint(:email)` in `User.changeset/2`. A duplicate then returns `{:error, changeset}` from `Repo.insert/1`. (Rule, in `references/ecto-phoenix.md`: Validate input with changesets.)

8. **A catch-all clause hides the cause.** `_ -> {:error, :insert_failed}` (lines 33-34) discards the reason Ecto returns. Fix: match `{:error, changeset}` and pass it through, so the caller sees which field failed. (Rule: Match every expected shape and let unexpected ones crash.)

9. **One error reason covers four causes.** Lines 37, 40 and 41 return `{:error, :invalid}` for a duplicate email, an age under 18, an invalid email, and a non-string field. The caller cannot tell them apart. Fix: a `with` chain in `parse_attrs/1`, with `check_adult/1` returning `{:error, :underage}` and the field helpers returning field-specific reasons. (Rule: Chain fallible steps with `with`; normalize each step's error in a small private function.)

10. **`&&` joins two booleans.** `is_binary(email) && age >= 18` (line 21). Both sides return booleans, so `and` fits and checks that they are booleans. The `is_binary` check is also redundant, because `String.downcase/1` on line 12 already requires a binary. Fix: remove both; `string_field/2` does the type check. (Rule: Use `and`, `or`, `not` when the operands are booleans.)

11. **A single step is piped.** `params["email"] |> String.downcase()` (line 12). Fix: `String.downcase(raw_email)`. (Rule: Write pipelines that start with a value and read top to bottom; do not pipe a single step.)

12. **An option changes the return shape.** `if opts[:return_id], do: user.id, else: {:ok, user}` (line 31) returns an integer in one mode and a tuple in the other. Fix: remove `:return_id`. Callers read `user.id` from `{:ok, user}`. This removes an option, so existing callers must change. (Rule: Give each function one return shape.)

13. **Two booleans overlap.** `opts[:notify] && !opts[:silent]` (line 27). `silent` overrides `notify`, and the pair `notify: true, silent: true` has no sensible meaning. Fix: remove `:silent` and keep `notify: true`. `Keyword.validate!/2` now raises on `silent:`, so old callers fail at once. (Rule: Use one atom-valued field or option instead of overlapping booleans.)

14. **The welcome email runs in an unsupervised process and copies the whole user.** `spawn(fn -> Mailer.deliver(welcome_email(user)) end)` (line 49) starts a process that no supervisor tracks, and the closure captures the full `user`. Fix: build the message in the caller and start it with `Task.Supervisor.start_child/2` under `Accounts.TaskSupervisor`, which must be started in the application's supervision tree. (Rules, in `references/processes.md`: Supervise every long-lived process; Send processes only the data they need.)

15. **An anonymous function is piped.** `greeting |> (fn text -> text <> " Enjoy your account." end).()` (line 55). Fix: one interpolated string. (Rule: Write pipelines that start with a value and read top to bottom; do not pipe into an anonymous function call.)

16. **Documentation and option checks are missing.** Line 2 is a comment where `@moduledoc` belongs. Line 5 is a comment where `@doc` belongs. `opts` is never checked. Fix: add `@moduledoc`, a `@doc` with `## Options`, and `Keyword.validate!/2`. (Rules: Document modules and public functions with `@moduledoc` and `@doc`; Group related parameters.)

17. **Two comments restate the code.** `# Get the role from params` (line 7) and `# send the email` (line 48). Fix: delete both. Line 11 explains why the address is lowercased, so it stays. (Rule: Comments explain why; documentation goes in `@moduledoc` and `@doc`.)

18. **Magic numbers.** `18` (line 21) and `120` (line 15) appear inline. Fix: `@min_age` and `@max_age`. (Rule: Name magic numbers with module attributes.)

## Assumptions and behavior changes

- `User.changeset/2` must cast the fields, declare `role` as `Ecto.Enum`, and call `unique_constraint(:email)`. I did not see the `User` module.
- `Accounts.TaskSupervisor` must exist. The name is a guess based on the module namespace.
- `Mailer` is kept as written. I did not see its module.
- A duplicate email now returns `{:error, changeset}` instead of `{:error, :invalid}`.
- The `:return_id` and `:silent` options are removed.
- The `## Examples` section that the Documentation rule asks for is not added. A doctest would need a database, and I did not have the test setup.
- The improved module passes `mix format --check-formatted`. It was not compiled, because `User` and `Repo` are not in this project.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from external CSV (comma-separated values) and JSON (JavaScript Object Notation) sources.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from string-keyed `params`.

  Returns `{:ok, user}` on success. Returns `{:error, {:missing_field, key}}` or
  `{:error, {:invalid_field, key}}` for a bad input field, `{:error, :underage}` for an
  age below 18, and `{:error, changeset}` when the database rejects the user, such as on
  a duplicate email. Ages above 120 are stored as 120.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, attrs} <- parse_attrs(params),
         {:ok, user} <- insert_user(attrs) do
      if opts[:notify], do: send_welcome(user)

      {:ok, user}
    end
  end

  defp parse_attrs(params) do
    with {:ok, raw_email} <- string_field(params, "email"),
         {:ok, age_text} <- string_field(params, "age"),
         {:ok, age} <- parse_integer(age_text, "age"),
         {:ok, role} <- string_field(params, "role"),
         :ok <- check_adult(age) do
      # The provider lowercases addresses before its uniqueness check, so match it here
      email = String.downcase(raw_email)

      attrs = %{
        email: email,
        age: min(age, @max_age),
        role: role,
        nickname: params["nickname"] || email
      }

      {:ok, attrs}
    end
  end

  defp insert_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp string_field(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp parse_integer(text, key) do
    case Integer.parse(text) do
      {integer, ""} -> {:ok, integer}
      {_integer, _rest} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:invalid_field, key}}
    end
  end

  defp check_adult(age) when age >= @min_age, do: :ok
  defp check_adult(_age), do: {:error, :underage}

  defp send_welcome(user) do
    message = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(message) end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```
