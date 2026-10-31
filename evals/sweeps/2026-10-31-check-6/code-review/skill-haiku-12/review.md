# Review: `code-review-input.ex`

Checked against the idiomatic-elixir skill (`SKILL.md`, plus `references/ecto-phoenix.md` and `references/processes.md`, which the file's `Repo` and `spawn` trigger).

1. **Atom created from user input (line 8).** `String.to_atom(params["role"])` makes a new atom for every distinct role string, and atoms are never garbage-collected, so a caller can exhaust the atom table and crash the node. A missing role also crashes here. Fix: map each accepted role to an atom with explicit clauses (`parse_role/1`).

2. **Age clamp does nothing (lines 15-17).** `age = 120` is rebound inside an `if`, and the new value does not leave the block, so an age of 150 is stored as 150. Fix: `age: min(age, @max_age)` in the attributes map.

3. **Lookup before insert, and an unvalidated struct (lines 22-25, 33-34).** `Repo.get_by(User, email: email) == nil` followed by `Repo.insert(user)` is a race: two imports of the same address can both pass the check, and the second insert then fails. The `_ ->` clause turns that failure into `:insert_failed`, which hides the reason. The struct is also inserted without validation. Fix: build the record with `User.changeset/2`, declare `unique_constraint(:email)` in that changeset, and return `{:error, changeset}` from the insert. The database unique index stays as the real guard.

4. **`try`/`rescue` around the whole function (lines 10, 13, 42-43).** `rescue _ ->` hides every error, including bugs, and turns each one into `{:error, :invalid}`. `String.to_integer/1` raises on bad input, which is the only reason the `rescue` is there. Fix: use `Integer.parse/1`, return a reason per failure (`{:invalid_field, "age"}`, `{:unknown_role, value}`), and remove the `try`.

5. **Email is downcased before it is checked (lines 12, 21).** `String.downcase(nil)` raises before `is_binary(email)` on line 21 can reject it. The one-step pipe `params["email"] |> String.downcase()` is also the rule's "do not pipe a single step" case. Fix: match `"email"` in the function head with an `is_binary/1` guard, then call `String.downcase(email)`.

6. **`&&` on booleans (lines 21, 27).** `and` raises if an operand is not a boolean, so it checks intent; `&&` accepts any value. Fix: the type check moves into the head guard and the age check into `parse_age/1`, so the improved code has no `&&`.

7. **Overlapping options (line 27).** `opts[:notify] && !opts[:silent]` combines two booleans where `silent: true` overrides `notify: true`. Fix: one atom option, `notify: :welcome`, with no email by default. Callers that passed `notify: true` must pass `:welcome`, and callers that passed `silent: true` simply stop passing `notify`. This is an API change.

8. **Two return shapes (line 31).** `if opts[:return_id], do: user.id, else: {:ok, user}` makes `import_user/2` return either a bare integer or a tuple, depending on an option. Fix: keep `import_user/2` returning `{:ok, user}`, and add `import_user_id/2` that returns `{:ok, id}`. Callers that passed `return_id: true` must switch to the new function, and they will now get `{:ok, id}` where they used to get a bare id.

9. **One long nested function (lines 6-45).** Three `if` levels and a `case` in one body make the success path hard to see. Fix: a `with` over named steps (`parse_params/1`, `insert_user/1`), each returning `{:ok, value}` or `{:error, reason}`, with `maybe_notify/2` after the insert.

10. **Struct read with `Access` (line 53).** `user[:name]` raises `UndefinedFunctionError` because structs do not implement `Access`. The crash happens inside the spawned process, so the welcome email is never sent and nothing reports why. Fix: `user.name || "there"`, which keeps the default for a `nil` name.

11. **Unsupervised `spawn` (line 49).** A bare `spawn/1` has no supervisor, so a crash is logged and forgotten, and nothing restarts or tracks it. The closure also copies `user` into the new process before the email is built. Fix: build the email in the caller and start it under `Task.Supervisor.start_child/2`. The application must start `Accounts.TaskSupervisor` in its supervision tree.

12. **Pipe into an anonymous function (line 55).** `greeting |> (fn text -> ... end).()` is hard to read and is not needed for one string. Fix: write the greeting as one interpolated string.

13. **Comments that restate the code, and docs in comments (lines 2, 5, 7, 48).** The module and function descriptions belong in `@moduledoc` and `@doc`, and `# Get the role from params` and `# send the email` repeat what the code says. The comment on line 11 explains a reason the code cannot show, so it stays, moved above the lowercasing call.

14. **Failures share one reason (lines 37, 40).** Every failure returns `{:error, :invalid}`, so a caller cannot tell a bad age from a duplicate email. Fix: distinct reasons from each step, listed in item 4.

## Assumptions in the improved code

- `Accounts.User.changeset/2` exists and declares `unique_constraint(:email)`. Its contents are not in the input file.
- `Accounts.TaskSupervisor` is started in the application's supervision tree.
- The roles `:admin`, `:editor` and `:member` are placeholders. Replace them with the roles the application defines.
- `Mailer` is the existing mailer module, as in the original.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from string-keyed params.

  Returns `{:ok, user}`, or `{:error, reason}` where `reason` names the invalid
  field, or is the `Ecto.Changeset` that failed to insert.

  ## Options

    * `:notify` - set to `:welcome` to send a welcome email after the insert.
      Defaults to sending none.
  """
  def import_user(params, opts \\ []) do
    with {:ok, attrs} <- parse_params(params),
         {:ok, user} <- insert_user(attrs) do
      maybe_notify(user, opts[:notify])
      {:ok, user}
    end
  end

  @doc """
  Imports a user as `import_user/2` does, and returns `{:ok, id}`.
  """
  def import_user_id(params, opts \\ []) do
    with {:ok, user} <- import_user(params, opts), do: {:ok, user.id}
  end

  defp parse_params(%{"email" => email, "age" => age, "role" => role} = params)
       when is_binary(email) do
    # The provider lowercases addresses before its uniqueness check, so match it here
    email = String.downcase(email)

    with {:ok, age} <- parse_age(age),
         {:ok, role} <- parse_role(role) do
      attrs = %{
        email: email,
        age: min(age, @max_age),
        role: role,
        nickname: params["nickname"] || email
      }

      {:ok, attrs}
    end
  end

  defp parse_params(_params), do: {:error, :invalid_params}

  defp parse_age(text) when is_binary(text) do
    case Integer.parse(text) do
      {age, ""} when age >= @min_age -> {:ok, age}
      _ -> {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(_text), do: {:error, {:invalid_field, "age"}}

  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("editor"), do: {:ok, :editor}
  defp parse_role("member"), do: {:ok, :member}
  defp parse_role(other), do: {:error, {:unknown_role, other}}

  defp insert_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp maybe_notify(user, :welcome), do: send_welcome(user)
  defp maybe_notify(_user, _notify), do: :ok

  defp send_welcome(user) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user), do: "Hi #{user.name || "there"}, welcome! Enjoy your account."
end
```
