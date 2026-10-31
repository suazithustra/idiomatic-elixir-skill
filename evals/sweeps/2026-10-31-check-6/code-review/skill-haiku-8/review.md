# Review: `Accounts.UserImporter`

The module imports one user from string-keyed params. Its age cap never applies, it turns outside input into atoms, and one `rescue` hides every failure as `:invalid`.

## Findings

1. The age cap does nothing. `if age > 120 do age = 120 end` (line 15) rebinds `age` inside the `if`, and the new value is lost when the block ends, so an age of 200 is stored as 200. Rule: "Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it". Fix: `min(value, @max_age)` in `parse_age/1`.

2. Outside input becomes an atom. `role = String.to_atom(params["role"])` (line 8) creates atoms from user-supplied text. Atoms are never freed, so a stream of made-up roles can exhaust the atom table and crash the VM (Erlang virtual machine). A missing role also raises here, outside the `try`. Rule: "Convert external strings to atoms with explicit clauses". Fix: `parse_role/1` with one clause per role.

3. The `rescue` hides every failure. `rescue _ -> {:error, :invalid}` (lines 42-43) turns database errors and real bugs into `:invalid`. Rule: "Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs". Fix: remove the `try`; each expected failure returns its own tuple.

4. Age parsing raises on bad input. `String.to_integer(params["age"])` (line 13) raises on `"abc"` or `nil`, and finding 3 hides that raise. Rule: "Call the non-raising version instead". Fix: `Integer.parse/1`, returning `{:error, {:invalid_field, "age"}}` on failure.

5. The struct is inserted without validation. `user = %User{email: email, age: age, role: role, nickname: nickname}` (line 22) goes straight to `Repo.insert(user)` (line 25), so no rule runs. Rule: "Validate input with changesets". Fix: `User.changeset/2` builds the insert.

6. The duplicate check runs before the insert. `if Repo.get_by(User, email: email) == nil do` (line 24) reads first and writes second, so two imports of one email can both pass. Rule: "Validate input with changesets", which says to declare `unique_constraint/3` in the changeset. Fix: the insert returns `{:error, changeset}` on a duplicate.

7. The insert has a catch-all clause. `_ -> {:error, :insert_failed}` (line 33) hides the changeset Ecto returns and any other shape. Rule: "Match every expected shape and let unexpected ones crash". Fix: `with` passes `{:error, changeset}` through unchanged.

8. The return shape depends on an option. `if opts[:return_id], do: user.id, else: {:ok, user}` (line 31) returns an integer in one mode and a tuple in the other. Rule: "Give each function one return shape". Fix: always return `{:ok, user}`; callers that need the ID read `user.id`.

9. Every error has the same reason. `{:error, :invalid}` (lines 37 and 40) covers a missing field, a bad age, an age under 18, and a duplicate email. Rule: "Different failures need different reasons too". Fix: each step returns its own reason.

10. The options overlap. `opts[:notify] && !opts[:silent]` (line 27) makes `notify: false, silent: true` do nothing and `notify: true, silent: true` silently skip the email. Rule: "Use one atom-valued field or option instead of overlapping booleans". Fix: one option, `notify: :none | :email`, checked with `Keyword.validate!/2`.

11. The boolean operators are the wrong ones. `if is_binary(email) && age >= 18 do` (line 21) uses `&&` on two booleans. Rule: "Use `and`, `or`, `not` when the operands are booleans". Fix: each check becomes its own step in a `with`.

12. The params are read without a check. `params["email"]` and `params["age"]` (lines 12-13) read keys that may be missing, so a missing key raises inside `try`. Rule: "A function that parses string-keyed input matches the keys it requires in its head". Fix: match `"email"`, `"age"`, and `"role"` in the head, with a fallback clause that returns `{:error, :invalid_params}`.

13. The welcome email runs in an unsupervised process. `spawn(fn -> Mailer.deliver(welcome_email(user)) end)` (line 49) is not under any supervisor, so a crash is lost and the process does not show in monitoring tools. Rule (`references/processes.md`): "Supervise every long-lived process". Fix: `Task.Supervisor.start_child/2`.

14. The spawned closure copies the whole user. The closure on line 49 captures `user` and builds the email inside the new process. Rule (`references/processes.md`): "Send processes only the data they need". Fix: build the message first, so the closure captures only `message`.

15. `user[:name]` raises on a struct. Structs do not implement `Access`, so `user[:name]` (line 53) raises `UndefinedFunctionError`. Rule: "Read required keys with `map.key` or a pattern; keep `map[:key]` for optional keys", with the note on structs. Fix: `Map.get(user, :name) || "there"`, because the name is optional.

16. A pipe runs into an anonymous function. `greeting |> (fn text -> text <> " Enjoy your account." end).()` (line 55) is hard to read. Rule: "Do not pipe into an anonymous function call". Fix: one string interpolation.

17. A single-step pipe. `params["email"] |> String.downcase()` (line 12) pipes one call. Rule: "Do not pipe a single step". Fix: `String.downcase/1` called directly, inside `normalize_email/1`.

18. The control flow is nested four levels deep. The `try`, the `if` on age, the `if` on email, the `if` on the duplicate check, and the `case` on the insert nest inside one another (lines 10-44). Rule: "Chain fallible steps with `with`; normalize each step's error in a small private function". Fix: one `with` chain, with one private function per step.

19. Comments restate the code, and the docs are in comments. Lines 2, 5, 7, and 48 describe what the code does, and the module has no `@moduledoc` or `@doc`. Rule: "Comments explain why; documentation goes in `@moduledoc` and `@doc`". Fix: move the description into `@moduledoc` and `@doc`, and delete the restating comments. The comment on line 11 explains a reason, so it stays.

## Assumptions in the improved code

- `User.changeset/2` casts and validates the fields and calls `unique_constraint(:email)`. The module does not show it.
- `:admin`, `:editor`, and `:member` are placeholder roles. Replace them with the app's roles.
- `Accounts.TaskSupervisor` must be in the application's supervision tree.
- The `Mailer` module is assumed to exist, as in the original.
- `:return_id` and `:silent` are removed. A caller that passes them now gets an error from `Keyword.validate!/2`. A caller that matched `{:error, :invalid}` must match the new reasons.
- If `User` has a `name` field, `user.name` is the simpler read on line 53 of the original.

## Improved version

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from external CSV (comma-separated values) or JSON sources.
  """

  alias Accounts.{Repo, User}

  @max_age 120
  @min_age 18

  @doc """
  Imports one user from string-keyed params.

  Returns `{:ok, user}` on success. On failure it returns `{:error, reason}`:

    * `:invalid_params` - `"email"`, `"age"`, or `"role"` is missing
    * `{:invalid_field, field}` - `"email"` or `"age"` is not usable, or the age is under 18
    * `{:unknown_role, role}` - `"role"` is not a known role
    * `{:error, changeset}` - the database rejected the user, for example a duplicate email

  ## Options

    * `:notify` - `:email` sends a welcome email after the insert. Defaults to `:none`.
  """
  def import_user(params, opts \\ [])

  def import_user(%{"email" => email, "age" => age, "role" => role} = params, opts) do
    opts = Keyword.validate!(opts, notify: :none)

    with {:ok, email} <- normalize_email(email),
         {:ok, age} <- parse_age(age),
         :ok <- check_adult(age),
         {:ok, role} <- parse_role(role),
         {:ok, user} <- insert_user(params, email, age, role) do
      notify(user, opts[:notify])
      {:ok, user}
    end
  end

  def import_user(_params, _opts), do: {:error, :invalid_params}

  # The provider lowercases addresses before its uniqueness check, so match it here
  defp normalize_email(email) when is_binary(email), do: {:ok, String.downcase(email)}
  defp normalize_email(_email), do: {:error, {:invalid_field, "email"}}

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {value, ""} -> {:ok, min(value, @max_age)}
      _ -> {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(_age), do: {:error, {:invalid_field, "age"}}

  defp check_adult(age) when age >= @min_age, do: :ok
  defp check_adult(_age), do: {:error, {:invalid_field, "age"}}

  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("editor"), do: {:ok, :editor}
  defp parse_role("member"), do: {:ok, :member}
  defp parse_role(other), do: {:error, {:unknown_role, other}}

  defp insert_user(params, email, age, role) do
    attrs = %{
      email: email,
      age: age,
      role: role,
      nickname: params["nickname"] || email
    }

    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp notify(user, :email), do: send_welcome(user)
  defp notify(_user, :none), do: :ok

  defp send_welcome(user) do
    message = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(message) end)
  end

  defp welcome_email(user) do
    name = Map.get(user, :name) || "there"
    "Hi #{name}, welcome! Enjoy your account."
  end
end
```
