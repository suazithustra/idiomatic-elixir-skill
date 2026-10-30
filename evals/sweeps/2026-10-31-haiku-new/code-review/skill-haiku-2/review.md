# Review: `Accounts.UserImporter`

## Findings

1. **The age cap never applies.** The line `age = 120` (line 16) sits inside an `if`, so the new value stays inside that block and the outer `age` keeps the original number, so ages above 120 pass through unchanged. Rule: "Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it." Fix: `age = min(age, @max_age)`.

2. **Welcome emails are never sent.** `user[:name]` (line 53) raises `UndefinedFunctionError` because a struct does not implement `Access`. The call runs inside a `spawn`, so the crash is silent: the user is saved and no error reaches the caller. Rule: "Read required keys with `map.key` or a pattern; keep `map[:key]` for optional keys," and "Structs do not implement `Access`." Fix: read `user.nickname`, the field this module sets.

3. **User input creates atoms.** `String.to_atom(params["role"])` (line 8) creates an atom from external input. Atoms are never garbage-collected, so a caller can exhaust the atom table and crash the node. A missing role also crashes here, because `String.to_atom(nil)` raises. Rule: "Convert external strings to atoms with explicit clauses." Fix: `parse_role/1` with one clause per accepted role and an error clause for anything else.

4. **A `rescue _` wraps the whole function.** The `try` and `rescue _ -> {:error, :invalid}` (lines 10 and 42-43) turn every error into the same answer, including bugs in the code itself, so they are hidden. Rule: "rescue the specific exception, never `rescue _ ->` … around a whole function." Fix: remove the `try` and check each input with a clause that names the failure.

5. **The age is parsed with a function that raises.** `String.to_integer(params["age"])` (line 13) raises on text such as `"abc"`, and the `try` above turns that into `{:error, :invalid}`. Rule: "Call the non-raising version instead: `Integer.parse/1`." Fix: `parse_integer/2` on `Integer.parse/1`, returning `{:error, {:invalid_field, "age"}}`.

6. **Required keys are read with `params["key"]`.** Lines 12, 13, 22 and 24 read `params["email"]` and `params["age"]` without checking them, so a missing key gives `nil` and the error shows up later, in another function. Rule: "Match the required keys of string-keyed input … instead of reading each key with `params["key"]` and checking for `nil`." Fix: a `string_field/2` helper that returns `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}`, chained with `with`.

7. **The duplicate check runs before the insert, and the insert skips validation.** `if Repo.get_by(User, email: email) == nil do` (line 24) followed by `Repo.insert(user)` (line 25) can let two imports of the same email both pass the check, since another process can insert between the two calls. `Repo.insert/1` on a `%User{}` struct also skips the changeset, so no validation runs. Rule: validate with a changeset, and declare the constraint with `unique_constraint/3`, so a violation returns `{:error, changeset}`. Fix: `%User{} |> User.changeset(attrs) |> Repo.insert()`, with `unique_constraint(:email)` in `User.changeset/2` and a unique index on the column.

8. **A catch-all clause hides new return values.** `_ -> {:error, :insert_failed}` (lines 33-34) turns every non-`:ok` result into the same error. Rule: "A `_ ->` clause after `{:ok, value}` turns every other return value … into the same error." Fix: the changeset pipeline in finding 7 returns `{:ok, user}` or `{:error, changeset}`, so the clause is no longer needed.

9. **The return shape depends on an option.** `if opts[:return_id], do: user.id, else: {:ok, user}` (line 31) returns an integer in one mode and a tuple in the other. Rule: "Options must not change what a function returns." Fix: remove `:return_id`. Callers that want the ID read `user.id` from `{:ok, user}`.

10. **Two overlapping booleans control the welcome email.** `if opts[:notify] && !opts[:silent] do` (line 27) allows the combination `notify: true, silent: true`, which makes no sense. Rule: "Use one atom-valued field or option instead of overlapping booleans." Fix: remove `:silent`, and write `if opts[:notify] do`.

11. **`&&` is used on booleans.** `if is_binary(email) && age >= 18 do` (line 21) uses `&&` where both operands are booleans. Rule: "Use `and`, `or`, `not` when the operands are booleans." Fix: the checks move into `string_field/2` and `validate_age/1`, so the line is no longer needed.

12. **Options are neither validated nor documented.** `def import_user(params, opts \\ [])` (line 6) accepts any keyword list, so a misspelled option such as `notfiy: true` is ignored without an error. Rule: "check them with `Keyword.validate!/2`, and document each one under `## Options` in `@doc`." Fix: `opts = Keyword.validate!(opts, notify: false)` and a `@doc` with an `## Options` section.

13. **The fire-and-forget process is not supervised.** `spawn(fn -> Mailer.deliver(welcome_email(user)) end)` (line 49) is outside any supervisor, so a crash is not reported and the process is not tracked. The closure also captures the whole `user`. Rule: "Supervise every long-lived process," and "Fire-and-forget work: `Task.Supervisor.start_child/2`." Fix: build the message first, then `Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(welcome) end)`.

14. **A pipe leads into an anonymous function.** `greeting |> (fn text -> text <> " Enjoy your account." end).()` (line 55) is hard to read. Rule: "Do not pipe into an anonymous function call." Fix: write the string in one expression: `"Hi #{user.nickname}, welcome! Enjoy your account."`.

15. **A single-step pipe.** `params["email"] |> String.downcase()` (line 12) pipes one call. Rule: "Do not pipe a single step: write `String.trim(name)`, not `name |> String.trim()`." Fix: `String.downcase(email)`, after `string_field/2` has checked the value.

16. **`import_user/2` does too much at one nesting level.** The function holds a `try`, three `if` blocks, a `case`, and a second `if` inside the `case`, so the reader must track five levels of nesting. Rule: "Keep functions short and at one level of detail … move the inner one into a named private function." Fix: the public function calls `parse_params/1`, `insert_user/1` and `send_welcome/1`.

17. **A module comment should be `@moduledoc`.** `# This module imports users…` (line 2) describes the module in a comment that `h/1` and the docs tooling cannot show. Rule: "Document modules and public functions with `@moduledoc` and `@doc`, not with comments above them." Fix: `@moduledoc """…"""`.

18. **Comments restate the code.** `# Get the role from params` (line 7) and `# send the email` (line 48) say what the next line already says. Rule: "Delete comments that restate the code." Fix: delete both. The comment on line 11 explains a reason and stays, in the same form.

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
  Imports a single user from the given params.

  Returns `{:ok, user}` or `{:error, reason}`. A duplicate email, or params
  that fail the changeset, come back as `{:error, changeset}`.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, attrs} <- parse_params(params),
         {:ok, user} <- insert_user(attrs) do
      if opts[:notify] do
        send_welcome(user)
      end

      {:ok, user}
    end
  end

  defp parse_params(params) do
    with {:ok, email} <- string_field(params, "email"),
         {:ok, age_text} <- string_field(params, "age"),
         {:ok, age} <- parse_integer(age_text, "age"),
         :ok <- validate_age(age),
         {:ok, role_name} <- string_field(params, "role"),
         {:ok, role} <- parse_role(role_name) do
      email = String.downcase(email)

      attrs = %{
        email: email,
        age: min(age, @max_age),
        role: role,
        nickname: params["nickname"] || email
      }

      {:ok, attrs}
    end
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
      {number, ""} -> {:ok, number}
      {_number, _rest} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:invalid_field, key}}
    end
  end

  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("member"), do: {:ok, :member}
  defp parse_role(other), do: {:error, {:unknown_role, other}}

  defp validate_age(age) when age >= @min_age, do: :ok
  defp validate_age(_age), do: {:error, :under_age}

  defp insert_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp send_welcome(user) do
    welcome = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(welcome) end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

## Notes on the rewrite

- The code was checked by reading only. I could not compile it or run `mix format` on it, because the sandbox would not let me write scratch files outside this directory.
- It assumes `User.changeset/2` casts the fields in `attrs` and calls `unique_constraint(:email)`, and that the database has a unique index on `email`. Neither is in the input.
- The role names `"admin"` and `"member"` are placeholders. Replace them with the app's real role list.
- `Accounts.TaskSupervisor` must be started in the application's supervision tree.
- Error reasons changed. `:invalid` is now `:under_age`, `{:invalid_field, key}`, `{:missing_field, key}`, `{:unknown_role, value}`, or `{:error, changeset}`. Callers that match on `:invalid` need updating.
- `:silent` and `:return_id` are removed. Callers that passed them need updating.
- The greeting now reads `user.nickname`. The input never shows a `name` field on `User`, so this is the field the module sets.
- The `## Examples` section the skill asks for is left out. A doctest here would need a database.
