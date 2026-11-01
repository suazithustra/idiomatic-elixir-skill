# Review: `Accounts.UserImporter`

The module has a silent crash, a clamp that never runs, and error handling that hides causes. The fixes below follow the idiomatic-elixir rules, and the improved version applies all of them.

## Findings

1. **The age clamp never runs.** Line 15 `if age > 120 do`, with `age = 120` on line 16, rebinds `age` inside the `if` block, and that value is lost when the block ends, so ages above 120 are stored unchanged. Rule: "Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it". Fix: `parse_age/1` returns `min(age, @max_age)`.

2. **The welcome email always crashes.** Line 53 `name = user[:name] || "there"` reads a `User` struct with `Access`. Structs do not implement `Access`, so this raises `UndefinedFunctionError`. The call runs in a spawned process, so nobody sees the error. Rule: "Read required keys with `map.key` or a pattern; keep `map[:key]` for optional keys", in the paragraph that says "Structs do not implement `Access`". Fix: `user.nickname`, which `parse_params/1` always sets.

3. **The `rescue` hides bugs.** Line 10 `try do` and line 43 `_ -> {:error, :invalid}` turn any exception, including a typo in this module, into the same `:invalid` error. Rule: "Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs". Fix: remove the `try`. `Integer.parse/1` replaces `String.to_integer/1`, and each field check returns a tagged reason.

4. **Input creates atoms.** Line 8 `role = String.to_atom(params["role"])` creates an atom for every new role string, and atoms are never freed. A missing role also raises. Rule: "Convert external strings to atoms with explicit clauses". Fix: `parse_role/1` has one clause per accepted role and returns `{:error, {:unknown_role, other}}` for the rest.

5. **Lookup, then insert, is a race.** Lines 22 to 25 build a `%User{}` struct, check `Repo.get_by(User, email: email) == nil`, and then call `Repo.insert(user)`. Two requests with the same email can both pass the check, and a duplicate that gets through raises instead of returning an error. Rule: "Validate input with changesets" in `ecto-phoenix.md`, which names `unique_constraint/3` for this case. Fix: `User.changeset/2` casts and validates the attributes and declares `unique_constraint(:email)`, and `Repo.insert/1` returns `{:error, changeset}` for a duplicate.

6. **The catch-all hides the reason.** Line 33 `_ -> {:error, :insert_failed}` replaces every failure from `Repo.insert/1` with one atom. Rule: "Match every expected shape and let unexpected ones crash". Fix: `insert_user/1` returns the result of `Repo.insert/1` as is.

7. **Different failures share one error.** Lines 37, 40 and 43 return `{:error, :invalid}` for a bad email, an under-age user, and a duplicate. A caller cannot tell them apart. Rule: "Different failures need different reasons too" (from "Match every expected shape and let unexpected ones crash"). Fix: `parse_params/1` returns `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}`, and a duplicate returns `{:error, changeset}`.

8. **A bare `spawn` is unsupervised.** Line 49 `spawn(fn -> Mailer.deliver(welcome_email(user)) end)` starts a process that no supervisor owns, so a failed delivery is lost. Rule: "Supervise every long-lived process" in `processes.md`, which names `Task.Supervisor.start_child/2` for fire-and-forget work. Fix: `Task.Supervisor.start_child/2`, and the closure captures only the message string.

9. **The return shape depends on an option.** Line 31 `if opts[:return_id], do: user.id, else: {:ok, user}` returns an integer in one mode and a tuple in the other. Rule: "Give each function one return shape". Fix: remove `:return_id`. `import_user/2` always returns `{:ok, user}`, and a caller that needs the ID reads `user.id`.

10. **Two booleans overlap.** Line 27 `if opts[:notify] && !opts[:silent] do` accepts `notify: true, silent: true` and quietly picks one reading. Rule: "Use one atom-valued field or option instead of overlapping booleans". Fix: one `:welcome` option with the value `:send` or `:skip`, defaulting to `:skip`.

11. **Options are not checked or documented.** Line 6 `def import_user(params, opts \\ [])` has no `@doc` and no check on `opts`, so a misspelled option such as `notfy: true` is ignored. Rule: "Group related parameters", which says to check optional settings with `Keyword.validate!/2` and document each one under `## Options` in `@doc`. Fix: `Keyword.validate!/2` and a `@doc` with an `## Options` section.

12. **Nested `if` blocks hide the success path.** Lines 15 to 41 nest four `if` and `case` levels. Rule: "Chain fallible steps with `with`; normalize each step's error in a small private function". Fix: a `with` over `parse_params/1` and `insert_user/1`, where each step is a private function.

13. **Validation runs in the wrong order.** Line 12 `params["email"] |> String.downcase()` runs before the type check, and it is a one-step pipe. Line 21 `if is_binary(email) && age >= 18 do` combines two checks with `&&`. Rules: "Do not pipe a single step" and "Use `and`, `or`, `not` when the operands are booleans". Fix: `required_string/2` checks the type before `String.downcase/1` runs, and `parse_age/1` checks the minimum age with a guard.

14. **A pipe runs into an anonymous function.** Line 55 `greeting |> (fn text -> text <> " Enjoy your account." end).()`. Rule: "Do not pipe into an anonymous function call". Fix: one interpolated string.

15. **Magic numbers.** Lines 15 and 21 use `120` and `18` directly. Rule: "Name magic numbers with module attributes". Fix: `@min_age 18` and `@max_age 120`.

16. **Comments stand in for docs and restate code.** Line 2 describes the module in a comment, line 5 describes the function in a comment, and lines 7 and 48 restate the next line. Rule: "Comments explain why; documentation goes in `@moduledoc` and `@doc`", which also says "Delete comments that restate the code". Fix: `@moduledoc` and `@doc`, and delete the restating comments. Line 11 stays, because it explains why the email is lowercased.

## Improved version

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external source.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from string-keyed `params`.

  Returns `{:ok, user}` on success. On failure, returns `{:error, reason}`,
  where `reason` is `{:missing_field, key}` or `{:invalid_field, key}` for
  bad input, or `{:error, changeset}` when the database rejects the row, such
  as a duplicate email.

  ## Options

    * `:welcome` - `:send` sends a welcome email after the insert, and `:skip`
      sends none. Defaults to `:skip`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, welcome: :skip)

    with {:ok, attrs} <- parse_params(params),
         {:ok, user} <- insert_user(attrs) do
      maybe_send_welcome(user, opts[:welcome])
      {:ok, user}
    end
  end

  defp parse_params(params) do
    with {:ok, raw_email} <- required_string(params, "email"),
         {:ok, raw_role} <- required_string(params, "role"),
         {:ok, role} <- parse_role(raw_role),
         {:ok, raw_age} <- required_string(params, "age"),
         {:ok, age} <- parse_age(raw_age) do
      # The provider lowercases addresses before its uniqueness check, so match it here
      email = String.downcase(raw_email)

      attrs = %{
        email: email,
        age: age,
        role: role,
        nickname: params["nickname"] || email
      }

      {:ok, attrs}
    end
  end

  defp required_string(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("editor"), do: {:ok, :editor}
  defp parse_role("viewer"), do: {:ok, :viewer}
  defp parse_role(other), do: {:error, {:unknown_role, other}}

  defp parse_age(raw_age) do
    case Integer.parse(raw_age) do
      {age, ""} when age >= @min_age -> {:ok, min(age, @max_age)}
      {_age, _rest} -> {:error, {:invalid_field, "age"}}
      :error -> {:error, {:invalid_field, "age"}}
    end
  end

  defp insert_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp maybe_send_welcome(user, :send), do: send_welcome(user)
  defp maybe_send_welcome(_user, :skip), do: :ok

  defp send_welcome(user) do
    message = welcome_message(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(message) end)
  end

  defp welcome_message(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

## Assumptions and behavior changes

- Callers that pass `notify: true` must pass `welcome: :send`. The `:silent` and `:return_id` options are gone.
- Ages above 120 are now stored as 120. Before, the clamp did nothing, so they were stored unchanged.
- A duplicate email now returns `{:error, changeset}`. This needs a unique index on the email column and `unique_constraint(:email)` in `User.changeset/2`.
- The roles `admin`, `editor`, and `viewer` are placeholders. Replace them with the application's real roles.
- `Accounts.TaskSupervisor` must be started in the application's supervision tree.
- The greeting uses `user.nickname`. If the greeting should use a different name field, change `welcome_message/1`.
- The code has not been compiled or run against the project, because it depends on `Repo`, `User`, and `Mailer`, which are not in the input.
