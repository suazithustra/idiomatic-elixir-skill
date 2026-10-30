# Review: `Accounts.UserImporter`

Rules are from `skill/SKILL.md` unless marked with its reference file (`references/ecto-phoenix.md` or `references/processes.md`).

## Findings

1. **Age cap does nothing.** Rule: "Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it". Line 16, `age = 120` inside `if age > 120 do`, is local to the block, so a 150-year-old is stored as 150. Fix: `age: min(age, @max_age)`.

2. **Welcome email never sends.** Rule: "Read required keys with `map.key` or a pattern". Line 53, `user[:name] || "there"`, raises `UndefinedFunctionError` because structs do not implement `Access`. The crash happens in the spawned process, so nothing is logged to the caller. Fix: build the greeting from `user.nickname`, which the import always sets.

3. **Role string converted to an atom.** Rule: "Convert external strings to atoms with explicit clauses", plus `references/ecto-phoenix.md`, "Use `Ecto.Enum` for fields with a fixed set of atom values". Line 8, `String.to_atom(params["role"])`, lets input create atoms until the VM (virtual machine) hits its atom limit and the node crashes. A missing role also raises outside the `try`. Fix: pass the role string to the changeset and let `Ecto.Enum` cast it.

4. **Catch-all rescue hides bugs.** Rule: "Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs". Lines 42-43, `rescue _ -> {:error, :invalid}`, turn every failure into `:invalid`, including a database outage or a typo in the code. Fix: remove the `try` and use non-raising calls.

5. **Raising integer parse.** Rule: "Do not wrap a raising call in `try/rescue` to get a tuple. Call the non-raising version instead". Line 13, `String.to_integer(params["age"])`, raises on `"abc"` or `nil`. Fix: `Integer.parse/1` with explicit clauses in `parse_age/1`.

6. **Insert without a changeset.** Rule: `references/ecto-phoenix.md`, "Validate input with changesets". Lines 22 and 25, `%User{...}` passed to `Repo.insert(user)`, skip all validation. Fix: `Repo.insert(User.changeset(%User{}, attrs))`.

7. **Check-then-insert race.** Rule: `references/ecto-phoenix.md`, "Declare database constraints in the changeset (`unique_constraint/3`...)". Line 24, `Repo.get_by(User, email: email) == nil`, lets two concurrent imports of the same address both pass the check. Fix: declare `unique_constraint(:email)` in `User.changeset/2` and let a duplicate return `{:error, changeset}`.

8. **Insert error replaced by a fixed atom.** Rule: "Match every expected shape and let unexpected ones crash". Lines 33-34, `_ -> {:error, :insert_failed}`, discard the changeset that says which field failed. Fix: the `with` passes `{:error, changeset}` through.

9. **Bare `spawn` with the whole user captured.** Rule: `references/processes.md`, "Supervise every long-lived process" and "Send processes only the data they need". Line 49, `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`, is not under a supervisor, so a crash is not reported or restarted. Fix: build the email first and start it with `Task.Supervisor.start_child/2`.

10. **Option changes the return shape.** Rule: "Give each function one return shape". Line 31, `if opts[:return_id], do: user.id, else: {:ok, user}`, returns a bare ID in one mode and a tuple in the other. Fix: a second function, `import_user_id/2`, returns `{:ok, id}`.

11. **Overlapping booleans.** Rule: "Use one atom-valued field or option instead of overlapping booleans". Line 27, `opts[:notify] && !opts[:silent]`, has a `:silent` option that only matters when `:notify` is set. Fix: keep `:notify` and drop `:silent`. Callers that pass `silent:` now get an error from `Keyword.validate!/2`.

12. **`&&` on booleans and a dead type check.** Rule: "Use `and`, `or`, `not` when the operands are booleans". Line 21, `is_binary(email) && age >= 18`, uses `&&`. The `is_binary` check is also dead, because line 12 already called `String.downcase/1` on the value. Fix: match binary strings in the function head with a guard, and use `and` in `parse_age/1`.

13. **Five levels of nesting in one function.** Rule: "Keep functions short and at one level of detail" and "Chain fallible steps with `with`". Lines 15-41 nest `if`, `if`, `if`, `case` and `if` inside a `try`. Fix: split into `user_attrs/1`, `parse_age/1`, and a `with` chain in `import_user/2`.

14. **Options not validated and no `@doc`.** Rule: "Group related parameters" (`Keyword.validate!/2`) and "Comments explain why; documentation goes in `@moduledoc` and `@doc`". Line 6 has no `@doc` and no option check; the comment on line 5 does the job of `@doc`. Fix: add `@doc` with an `## Options` section and call `Keyword.validate!/2`.

15. **Pipe into an anonymous function.** Rule: "Write pipelines that start with a value and read top to bottom", bullet "Do not pipe into an anonymous function call". Line 55, `greeting |> (fn text -> ... end).()`. Fix: one interpolated string in `welcome_email/1`.

16. **Single-step pipe.** Rule: same section as finding 15, bullet "Do not pipe a single step". Line 12, `params["email"] |> String.downcase()`. Fix: `String.downcase(email)`.

17. **Comments that restate code.** Rule: "Comments explain why; documentation goes in `@moduledoc` and `@doc`", first paragraph: delete comments that restate the code. Lines 7 (`# Get the role from params`) and 48 (`# send the email`) restate the next line. Line 5 is a doc comment and moves into `@doc`. Line 2 moves into `@moduledoc`. Line 11 explains a reason and stays.

## Improved version

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external source, such as a CSV (comma-separated values) file or a JSON feed.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from string-keyed params.

  Returns `{:ok, user}` or `{:error, reason}`. An age above 120 is stored as 120.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    notify? = Keyword.validate!(opts, notify: false)[:notify]

    with {:ok, attrs} <- user_attrs(params),
         {:ok, user} <- Repo.insert(User.changeset(%User{}, attrs)) do
      if notify?, do: send_welcome(user)
      {:ok, user}
    end
  end

  @doc """
  Like `import_user/2`, but returns `{:ok, id}` with the new user's ID instead of the user.
  """
  def import_user_id(params, opts \\ []) do
    with {:ok, user} <- import_user(params, opts), do: {:ok, user.id}
  end

  defp user_attrs(%{"email" => email, "age" => age} = params)
       when is_binary(email) and is_binary(age) do
    # The provider lowercases addresses before its uniqueness check, so match it here
    email = String.downcase(email)

    with {:ok, age} <- parse_age(age) do
      attrs = %{
        email: email,
        age: min(age, @max_age),
        role: params["role"],
        nickname: params["nickname"] || email
      }

      {:ok, attrs}
    end
  end

  defp user_attrs(_params), do: {:error, :invalid_payload}

  defp parse_age(text) do
    case Integer.parse(text) do
      {age, ""} when age >= @min_age -> {:ok, age}
      {_age, _rest} -> {:error, {:invalid_field, "age"}}
      :error -> {:error, {:invalid_field, "age"}}
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

## Assumptions and behavior changes

- `User.changeset/2` must cast `:email`, `:age`, `:role`, and `:nickname`, declare `role` as `Ecto.Enum`, validate the required fields, and call `unique_constraint(:email)`. The importer relies on these; the file does not show them.
- `Accounts.TaskSupervisor` must be started in the application's supervision tree (`{Task.Supervisor, name: Accounts.TaskSupervisor}`).
- A duplicate email now returns `{:error, changeset}` instead of `{:error, :invalid}`.
- Callers that passed `silent:` or `return_id:` now get an error from `Keyword.validate!/2`. Callers that wanted an ID use `import_user_id/2`.
- I did not run `mix format` or the compiler on the improved code, because the scratch directory was not writable from this session.
