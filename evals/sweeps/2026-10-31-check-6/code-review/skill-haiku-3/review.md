# Review: Accounts.UserImporter

## Findings

1. The age cap never applies. Lines 15-17 set `age = 120` inside an `if`, and a variable rebound inside a block does not leave it, so users over 120 are saved with their real age. Fix: `age = min(age, @max_age)`. (Rule: "Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it".)

2. The welcome email never sends. Line 53, `user[:name]`, raises because structs do not implement Access. The error happens inside the spawned process, so the caller never sees it. The module also never sets a `name` field; it sets `nickname`. Fix: `user.nickname`. (Rule: "Read required keys with `map.key` or a pattern; keep `map[:key]` for optional keys".)

3. Input text becomes an atom without limit. Line 8, `String.to_atom(params["role"])`, lets callers fill the atom table, and a missing role crashes on `nil`. Fix: keep role as a string and let the changeset cast it with `Ecto.Enum`. (Rule: "Convert external strings to atoms with explicit clauses".)

4. A broad `rescue` hides every bug. Lines 10 and 42-43 wrap the whole function in `try` and turn any error into `{:error, :invalid}`, including a `nil` email. `String.to_integer/1` on line 13 raises on input such as "abc". Fix: remove the `try` and use `Integer.parse/1`, which returns `:error` instead of raising. (Rule: "Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs".)

5. Different failures get the same reason. Lines 33-34, 37 and 40 turn a failed insert into `:insert_failed` and drop the changeset error, and a bad age, a bad email and a duplicate all return the same `:invalid`. Fix: return `{:error, changeset}` from the insert and distinct reasons such as `{:error, {:missing_field, "email"}}`, `{:error, {:invalid_field, "age"}}` and `{:error, :too_young}`. (Rule: "Match every expected shape and let unexpected ones crash".)

6. The uniqueness check is done by hand, and the struct is inserted without validation. Lines 22-25 call `Repo.get_by` and then `Repo.insert(user)`. Two imports of the same address can both pass the check, and nothing validates the struct. Fix: build the user with `User.changeset/2`, declare `unique_constraint(:email)` in that changeset, and pipe it into `Repo.insert/1`. (Reference: `references/ecto-phoenix.md`, "Validate input with changesets".)

7. The return shape depends on an option. Line 31, `if opts[:return_id], do: user.id, else: {:ok, user}`, makes the function return an integer in one mode and a tuple in the other. Fix: remove `:return_id`; callers read `user.id` from `{:ok, user}`. (Rule: "Give each function one return shape".)

8. Two options overlap. Line 27 combines `notify` and `silent`, and `notify: true, silent: true` has no clear meaning. Fix: remove `:silent`. Callers that pass `silent: true` will start sending welcome emails. (Rule: "Use one atom-valued field or option instead of overlapping booleans".)

9. One function nests four levels deep and uses `&&` on booleans. Lines 15-41 combine `if`, `case` and `if` with `&&` on line 21. Fix: a `with` chain of small private functions, each returning `{:ok, value}` or `{:error, reason}`, and `and` for boolean operands. (Rules: "Branch with function clauses and guards before reaching for `if` or `cond`"; "Keep functions short and at one level of detail"; "Use `and`, `or`, `not` when the operands are booleans".)

10. Input is checked after it is read, not where it enters. Lines 6-13 and 19 read `params["key"]` one key at a time and rely on later checks. Fix: a `string_field/2` helper that returns `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}`, chained in a `with`. (Rule: "Parse external data into structs where it enters the system".)

11. The string is piped into an anonymous function. Line 55, `greeting |> (fn text -> text <> " Enjoy your account." end).()`, is hard to read and breaks the pipe rule. Fix: build the text with string interpolation in one line. (Rule: "Write pipelines that start with a value and read top to bottom", the bullet on anonymous functions.)

12. The line 12 pipe has a single step. `params["email"] |> String.downcase()` should be `String.downcase(params["email"])`. (Rule: the same pipeline section, the bullet "Do not pipe a single step".)

13. The welcome process is not supervised. Line 49, `spawn/1`, starts a process outside any supervisor, so failures go unnoticed and the process has no shutdown order. Fix: `Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> ... end)`. (Reference: `references/processes.md`, "Supervise every long-lived process".)

14. The options are not validated. Line 6 takes `opts \\ []` and reads `opts[:notify]` without checking the keys, so a typo passes silently. Fix: `opts = Keyword.validate!(opts, notify: false)`. (Rule: "Group related parameters", which asks for `Keyword.validate!/2`.)

15. Comments restate the code or describe the public API. Lines 2 and 5 describe the module and the function, and lines 7 and 48 repeat the next line. Fix: put the description in `@moduledoc` and `@doc`, and delete lines 7 and 48. Keep line 11, which explains why the downcase is needed. (Rule: "Comments explain why; documentation goes in `@moduledoc` and `@doc`".)

## Improved version

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV (comma-separated values) or JSON (JavaScript Object Notation) source.
  """

  alias Accounts.{Repo, User}

  @max_age 120
  @min_age 18

  @doc """
  Imports one user from string-keyed params.

  Ages above 120 are stored as 120. Users under 18 are rejected.

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
    with {:ok, role} <- string_field(params, "role"),
         {:ok, raw_email} <- string_field(params, "email"),
         {:ok, age} <- integer_field(params, "age"),
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

  defp send_welcome(user) do
    email = welcome_email(user)

    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end

  defp string_field(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp integer_field(params, key) do
    with {:ok, text} <- string_field(params, key),
         {:ok, age} <- parse_integer(text, key) do
      {:ok, age}
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
  defp check_adult(_age), do: {:error, :too_young}
end
```

## Assumptions and changes for callers

- `User.changeset/2` must exist, cast `email`, `age`, `role` and `nickname`, validate `role` as an `Ecto.Enum`, and call `unique_constraint(:email)`. The module under review does not show the `User` schema.
- `Accounts.TaskSupervisor` must be started in the application's supervision tree.
- `:return_id` and `:silent` are gone. Callers that used them need to change, as described in findings 7 and 8.
- No `## Examples` doctest was added. A doctest for `import_user/2` needs a database, and the module has no test setup to show.
