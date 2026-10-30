# Review: `Accounts.UserImporter`

The welcome email never sends, the age cap never applies, and a blanket error handler turns every failure into `:invalid`. The rewrite below fixes these and the other findings. Rules come from the idiomatic-elixir skill (`SKILL.md`, `references/ecto-phoenix.md`, `references/processes.md`).

## Findings

1. Line 53, `name = user[:name] || "there"`. Structs do not support `[]` access, so this raises inside the spawned process and nothing reports it. Rule: "Read required keys with `map.key` or a pattern". Fix: greet with `user.nickname`, which the importer always sets.

2. Lines 15-17, `age = 120` inside an `if`. A variable rebound inside `if` stays inside it, so ages above 120 are stored unchanged. Rule: "Assign the result of `if`, `case`, and `Enum` calls". Fix: `age = min(age, @max_age)`. The limits 120 and 18 become module attributes, as the rule on magic numbers asks.

3. Line 8, `role = String.to_atom(params["role"])`. Every distinct string from input creates a new atom, and the VM (virtual machine) has a fixed atom limit, so enough input can crash the node. A missing role also raises here, outside the `try`. Rule: "Convert external strings to atoms with explicit clauses". Fix: pass the string to `User.changeset/2`, which casts it with `Ecto.Enum` (see assumptions).

4. Lines 10 and 42-43, `try ... rescue _ -> {:error, :invalid}` around the whole function. This hides database and code errors as "invalid". `String.to_integer/1` on line 13 raises on bad input, which is an expected failure. Rules: "Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs" and "never `rescue _ ->`". Fix: `Integer.parse/1` and changeset errors, with no `try`. Failures now return specific reasons such as `{:invalid_field, "age"}`.

5. Lines 22-25, a struct inserted after a lookup. `Repo.get_by(User, email: email) == nil` followed by `Repo.insert(user)` lets two requests with the same email both pass the check. The struct also skips validation. Rules: "Validate input with changesets" and "Declare database constraints in the changeset (`unique_constraint/3`...)" from `references/ecto-phoenix.md`. Fix: `User.changeset/2` declares `unique_constraint(:email)`, and the database's unique index turns a duplicate into `{:error, changeset}`.

6. Lines 33-34, `_ -> {:error, :insert_failed}`. A catch-all clause hides every other return value. Rule: "Match every expected shape and let unexpected ones crash". Fix: `Repo.insert/1` returns `{:error, changeset}` for expected failures, and the `with` passes it through.

7. Line 31, `if opts[:return_id], do: user.id, else: {:ok, user}`. On success this returns a bare integer, and otherwise a tuple. Rule: "Give each function one return shape". Fix: the option is removed. Callers read `user.id` from `{:ok, user}`.

8. Line 27, `if opts[:notify] && !opts[:silent]`. `silent` overrides `notify`, and `&&` and `!` accept any value where booleans are meant. Line 21 has the same `&&` in `is_binary(email) && age >= 18`. Rules: "Use one atom-valued field or option instead of overlapping booleans" and "Use `and`, `or`, `not` when the operands are booleans". Fix: `silent` is removed and `notify` stands alone. The `&&` check moves into the parsing functions. `Keyword.validate!/2` now raises on unknown options, so a caller that still passes `silent:` gets an error instead of a silent change.

9. Line 12, `email = params["email"] |> String.downcase()`. `String.downcase/1` raises on `nil` before line 21 checks `is_binary(email)`, and the pipe has one step. Rules: "Do not pipe a single step" and "Match every expected shape". Fix: `fetch_string/2` returns `{:error, {:missing_field, "email"}}` before any string function runs.

10. Line 49, `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`. A bare `spawn` is not supervised, so a crash is only logged, and the closure copies the whole `user`. Rules: "Supervise every long-lived process" and "Send processes only the data they need" from `references/processes.md`. Fix: `Task.Supervisor.start_child/2` with the message built first.

11. Line 55, `greeting |> (fn text -> text <> " Enjoy your account." end).()`. Piping into an anonymous function call is named as a mistake. Rule: "Do not pipe into an anonymous function call". Fix: one string with interpolation.

12. Line 6, `def import_user(params, opts \\ [])`. Nothing checks or documents the options. Rule: "Group related parameters", which asks for `Keyword.validate!/2` and a `## Options` section in `@doc`. Fix: `Keyword.validate!(opts, notify: false)`, with the option documented.

13. Lines 2, 5, 7, and 48, comments such as `# Get the role from params` and `# send the email`. These restate the code. Rule: "Comments explain why; documentation goes in `@moduledoc` and `@doc`". Fix: the first two comments become `@moduledoc` and `@doc`, and the other two are deleted. The comment on line 11 explains a reason and stays.

## Assumptions

The rewrite relies on things the input file does not show. Check each one against the project.

- `User.changeset/2` casts `email`, `age`, `role`, and `nickname`, and calls `unique_constraint(:email)`. The database has a unique index on `email`.
- `role` is an `Ecto.Enum` with the project's real role values. The input does not list them.
- `Accounts.TaskSupervisor` is started in the application's supervision tree.
- `Mailer` is unchanged.
- The greeting uses `nickname` because the input never sets a `name` field.

Callers see three changes: `silent:` now raises, `return_id:` is gone, and a duplicate email returns `{:error, changeset}` instead of `{:error, :invalid}`.

## Checks

`mix format --check-formatted` passes on the rewrite. It compiles and runs against stub modules for `User`, `Repo`, and `Mailer`, since the real modules are not in the input. The smoke run covered a capped age, an age under 18, a missing email, a non-numeric age, and `notify: true`.

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
  Imports a single user from string-keyed params.

  Returns `{:ok, user}`, or `{:error, reason}` where `reason` is a changeset
  or a `{:missing_field, key}` or `{:invalid_field, key}` tuple. Ages above 120
  are stored as 120. Ages below 18 are rejected.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, attrs} <- build_attrs(params),
         {:ok, user} <- insert_user(attrs) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  defp build_attrs(params) do
    with {:ok, email} <- fetch_string(params, "email"),
         {:ok, age} <- parse_age(params["age"]) do
      # The provider lowercases addresses before its uniqueness check, so match it here
      email = String.downcase(email)

      attrs = %{
        email: email,
        age: min(age, @max_age),
        role: params["role"],
        nickname: params["nickname"] || email
      }

      {:ok, attrs}
    end
  end

  defp insert_user(attrs), do: Repo.insert(User.changeset(%User{}, attrs))

  defp fetch_string(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp parse_age(value) when is_binary(value) do
    case Integer.parse(value) do
      {age, ""} when age >= @min_age -> {:ok, age}
      {_age, _rest} -> {:error, {:invalid_field, "age"}}
      :error -> {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(_value), do: {:error, {:invalid_field, "age"}}

  defp send_welcome(user) do
    message = welcome_message(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(message) end)
  end

  defp welcome_message(user), do: "Hi #{user.nickname}, welcome! Enjoy your account."
end
```
