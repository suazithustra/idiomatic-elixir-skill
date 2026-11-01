# Review: `Accounts.UserImporter`

## Findings

1. The age cap never takes effect. Lines 15–17 (`if age > 120 do age = 120 end`) rebind `age` inside an `if`, and that binding does not leave the block, so a value of 150 is imported as 150. Rule: "Assign the result of `if`, `case`, and `Enum` calls". Fix: `age = min(age, @max_age)`.

2. `String.to_atom(params["role"])` on line 8 creates atoms from input, and the atom table is never garbage-collected, so a caller can crash the node by sending many distinct roles. A missing role also raises. Rule: "Convert external strings to atoms with explicit clauses". Fix: pass the role as a string and let `Ecto.Enum` in `User.changeset/2` convert it, rejecting unknown values.

3. The `try ... rescue _ -> {:error, :invalid}` on lines 10 and 42–43 wraps the whole function and turns every exception, including bugs, into `{:error, :invalid}`. Rule: "rescue the specific exception, never `rescue _ ->`". Fix: remove the `try`; use non-raising calls and the changeset, which return tuples.

4. `String.to_integer(params["age"])` on line 13 raises on input such as `"abc"`. Rule: "Call the non-raising version instead". Fix: `Integer.parse/1`, with the result matched in `parse_age/1`.

5. Line 24, `if Repo.get_by(User, email: email) == nil`, checks for a duplicate before the insert. Two imports of the same address can both pass the check. Rule: the changeset rule names `unique_constraint/3` for this. Fix: declare `unique_constraint(:email)` in `User.changeset/2` and let the database decide; the duplicate comes back as `{:error, changeset}`.

6. Line 22 builds `%User{email: ..., age: ...}` and line 25 passes it straight to `Repo.insert/1`, so nothing is validated. Rule: "Validate input with changesets". Fix: `%User{} |> User.changeset(attrs) |> Repo.insert()`.

7. The `_ -> {:error, :insert_failed}` clause on line 33 catches every non-matching return. Rule: "Match every expected shape and let unexpected ones crash". Fix: no catch-all; `{:error, changeset}` passes through the `with`.

8. `{:error, :invalid}` is returned for four different causes (lines 37, 40, 43 and the rescue). A caller cannot tell a duplicate address from a missing field. Rule: "Different failures need different reasons". Fix: `{:missing_field, key}`, `{:invalid_field, key}`, and the changeset error.

9. `opts[:notify] && !opts[:silent]` on line 27 uses two overlapping booleans; `notify: true, silent: true` is a contradiction the code has to resolve. Rule: "Use one atom-valued field or option instead of overlapping booleans". Fix: remove `silent`. A caller that passed `silent: true` now gets the email when `notify: true` is also set; flagged under the notes below.

10. `if opts[:return_id], do: user.id, else: {:ok, user}` on line 31 makes one function return two shapes. Rule: "Give each function one return shape". Fix: `import_user/2` always returns `{:ok, user}`, and a new `import_user_id/2` returns `{:ok, id}`.

11. `spawn(fn -> Mailer.deliver(welcome_email(user)) end)` on line 49 starts an unsupervised process, and the closure copies the whole `user`. Rule: "Supervise every long-lived process" and "Send processes only the data they need". Fix: build the body first, then `Task.Supervisor.start_child/2` with a closure that captures only the body. This needs an `Accounts.TaskSupervisor` in the supervision tree.

12. `user[:name] || "there"` on line 53 raises, because a struct does not implement `Access`, and `%User{}` has no `name` field; the code sets `nickname`. Rule: "Read required keys with `map.key`" and "structs do not implement `Access`". Fix: use `user.nickname`, which is always set, since it falls back to the email.

13. `greeting |> (fn text -> text <> " Enjoy your account." end).()` on line 55 pipes into an anonymous function. Rule: "Do not pipe into an anonymous function call". Fix: one interpolated string.

14. `params["email"] |> String.downcase()` on line 12 pipes a single step. Rule: "Do not pipe a single step". Fix: `String.downcase(raw_email)`, which also returns an error instead of raising when the email is missing.

15. `is_binary(email) && age >= 18` on line 21 combines two booleans with `&&`. Rule: "Use `and`, `or`, `not` when the operands are booleans". Fix: the checks move into `parse_attrs/1` and the changeset, so the line goes away.

16. The function nests six levels deep (`try`, `if`, `if`, `if`, `case`, `if`). Rule: "Keep functions short and at one level of detail". Fix: a `with` chain of named private steps.

17. Comments on lines 2, 5, 7 and 48 restate the code or describe the module and function instead of explaining a reason. Rule: "Comments explain why; documentation goes in `@moduledoc` and `@doc`". Fix: lines 2 and 5 become `@moduledoc` and `@doc`, lines 7 and 48 are deleted, and the line 11 comment stays because it gives a reason.

## Improved version

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.{Repo, User}

  @max_age 120

  @doc """
  Imports a single user from string-keyed params and returns `{:ok, user}`
  or `{:error, reason}`.

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

  @doc """
  Imports a single user like `import_user/2` and returns `{:ok, id}`.
  """
  def import_user_id(params, opts \\ []) do
    with {:ok, user} <- import_user(params, opts) do
      {:ok, user.id}
    end
  end

  defp parse_attrs(params) do
    with {:ok, raw_email} <- fetch_string(params, "email"),
         {:ok, text} <- fetch_string(params, "age"),
         {:ok, age} <- parse_age(text) do
      # The provider lowercases addresses before its uniqueness check, so match it here
      email = String.downcase(raw_email)

      attrs = %{
        "email" => email,
        "age" => min(age, @max_age),
        "role" => params["role"],
        "nickname" => params["nickname"] || email
      }

      {:ok, attrs}
    end
  end

  defp fetch_string(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp parse_age(text) do
    case Integer.parse(text) do
      {age, ""} -> {:ok, age}
      {_age, _rest} -> {:error, {:invalid_field, "age"}}
      :error -> {:error, {:invalid_field, "age"}}
    end
  end

  defp insert_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp send_welcome(user) do
    body = "Hi #{user.nickname}, welcome! Enjoy your account."
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(body) end)
  end
end
```

## Companion changeset

The improved module depends on `User.changeset/2` doing the work the old code did by hand. A minimal version:

```elixir
def changeset(user, attrs) do
  user
  |> cast(attrs, [:email, :age, :role, :nickname])
  |> validate_required([:email, :age, :role])
  |> validate_number(:age, greater_than_or_equal_to: 18)
  |> unique_constraint(:email)
end
```

`role` must be declared as `field :role, Ecto.Enum, values: [...]` in the schema.

## Behavior changes to check

- `silent:` is no longer an option, and `Keyword.validate!/2` raises on unknown keys, so callers that pass `silent:` or `return_id:` must change.
- `import_user_id/2` returns `{:ok, id}` where `return_id: true` used to return a bare id.
- Users under 18 and duplicate emails return `{:error, changeset}` instead of `{:error, :invalid}`.
- The welcome text uses the nickname and no longer falls back to "there".
- `Accounts.TaskSupervisor` must be started in the application's supervision tree.
