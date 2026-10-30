# Review: `Accounts.UserImporter`

Source: `code-review-input.ex`. The module imports one user and optionally sends a welcome email. Its main faults: the age clamp never runs, the error handling hides bugs, and the uniqueness check is racy.

## Findings

1. Line 15-17, `if age > 120 do` / `age = 120`: The clamp to 120 never takes effect, because a variable rebound inside `if` stays inside it, so an age of 150 is stored as 150. Rule: "Assign the result of `if`, `case`, and `Enum` calls". Fix: `update_change(:age, &min(&1, 120))` in the changeset.

2. Line 8, `role = String.to_atom(params["role"])`: Any caller can create new atoms by sending new role names, and the VM (virtual machine) has a fixed atom limit, so this can crash the node. Rule: "Convert external strings to atoms with explicit clauses". Fix: declare `role` as an `Ecto.Enum` field, so the changeset casts only the listed values.

3. Line 10 and 42-44, `try do` / `rescue _ -> {:error, :invalid}`: The blanket rescue wraps the whole function and turns any bug into `:invalid`. Rule: "Use `rescue` only around third-party code ... never `rescue _ ->` ... around a whole function". Fix: remove the `try`; the changeset returns validation errors without raising.

4. Line 13, `age = String.to_integer(params["age"])`: This raises on a non-numeric age, and the rescue above then hides it. Rule: "Do not wrap a raising call in `try/rescue` to get a tuple. Call the non-raising version". Fix: Ecto's `cast/3` converts the age string to an integer and reports a bad value as a changeset error.

5. Line 24, `if Repo.get_by(User, email: email) == nil do`: A lookup before the insert is a race: two imports of the same email can both pass the check. Rule: "`unique_constraint/3`" in the changeset (`ecto-phoenix.md`, "Validate input with changesets"). Fix: `unique_constraint(:email)` in the changeset, with a unique index on `users.email`.

6. Line 22, `user = %User{email: email, age: age, role: role, nickname: nickname}`: The struct is built by hand and inserted with no validation. Rule: "Cast and validate external input with `Ecto.Changeset`" (`ecto-phoenix.md`). Fix: `User.import_changeset(%User{}, params)`, then `Repo.insert/1` on the changeset.

7. Line 33-34, `_ ->` / `{:error, :insert_failed}`: The catch-all hides the changeset that explains why the insert failed. Rule: "Match the error shape explicitly". Fix: `with {:ok, user} <- Repo.insert(changeset)` passes `{:error, changeset}` through unchanged.

8. Line 31, `if opts[:return_id], do: user.id, else: {:ok, user}`: One option changes what the function returns, so callers must check the option to know the shape. Rule: "Give each function one return shape". Fix: remove `:return_id`; callers that need the id read `user.id` from `{:ok, user}`. This is a breaking change for any caller that passes `return_id: true`.

9. Line 27, `if opts[:notify] && !opts[:silent] do`: Two booleans overlap, so `notify: true, silent: true` is a combination that means nothing. Rule: "Use one atom-valued field or option instead of overlapping booleans". Fix: drop `:silent`; a caller who does not want the email leaves out `notify:`.

10. Line 21, `if is_binary(email) && age >= 18 do`: The `&&` is used on two booleans, and `is_binary(email)` is never false here, because `String.downcase/1` on line 12 already raised for a non-string. Rule: "Use `and`, `or`, `not` when the operands are booleans". Fix: the age rule moves into the changeset as `validate_number(:age, greater_than_or_equal_to: 18)`.

11. Line 12, `email = params["email"] |> String.downcase()`: This pipes a single step. Rule: "Do not pipe a single step". Fix: the lowercasing moves into the changeset as `update_change(:email, &String.downcase/1)`.

12. Line 53, `name = user[:name] || "there"`: Structs do not implement `Access`, so `user[:name]` raises `UndefinedFunctionError`. Rule: "Structs do not implement `Access`: `user[:name]` raises `UndefinedFunctionError`" (`idiomatic-elixir` SKILL.md, "Read required keys"). Fix: `Map.get(user, :name) || "there"`. Open question: the importer never sets `name`, so the fallback "there" always applies. Confirm whether the greeting should use `nickname` instead.

13. Line 49, `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`: A bare `spawn` has no supervisor, so a crash is lost and the process is not visible in tools. Rule: "Supervise every long-lived process" (`processes.md`). Fix: `Task.Supervisor.start_child/2`, which needs `Accounts.TaskSupervisor` in the application's supervision tree.

14. Line 54-55, `greeting = "Hi " <> name <> ", welcome!"` and `greeting |> (fn text -> ... end).()`: The string is built with `<>` and then piped into an anonymous function call. Rule: "Do not pipe into an anonymous function call". Fix: one interpolated string, `"Hi #{name}, welcome! Enjoy your account."`.

15. Line 2, 6, 47 and the comments on lines 5, 7, 48: The module and function descriptions are plain comments, and the comments on lines 7 and 48 restate the code. Rule: "Document modules and public functions with `@moduledoc` and `@doc`" and "Delete comments that restate the code". Fix: `@moduledoc` and `@doc` replace the first two; the other two are deleted. The comment on line 11 explains a reason, so it stays, in the changeset.

## Improved module

Each finding above is applied in this code. Two helpers the code depends on are listed after it.

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV (comma-separated values) or JSON
  (JavaScript Object Notation) source.
  """

  alias Accounts.{Repo, User}

  @doc """
  Imports a single user from the given params.

  Returns `{:ok, user}` or `{:error, changeset}`. The changeset holds the
  validation errors, such as an age under 18, an unknown role, or an email
  that is already taken.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    changeset = User.import_changeset(%User{}, params)

    with {:ok, user} <- Repo.insert(changeset) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  defp send_welcome(user) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user) do
    name = Map.get(user, :name) || "there"
    "Hi #{name}, welcome! Enjoy your account."
  end
end
```

The changeset lives on `User`. This is the function to add to `Accounts.User`, or to a module it delegates to:

```elixir
@doc """
Casts and validates the params of one imported user.
"""
def import_changeset(user, params) do
  user
  |> cast(params, [:email, :age, :role, :nickname])
  # The provider lowercases addresses before its uniqueness check, so match it here
  |> update_change(:email, &String.downcase/1)
  |> update_change(:age, &min(&1, 120))
  |> validate_required([:email, :age, :role])
  |> validate_number(:age, greater_than_or_equal_to: 18)
  |> put_nickname_default()
  |> unique_constraint(:email)
end

defp put_nickname_default(changeset) do
  if get_field(changeset, :nickname) do
    changeset
  else
    put_change(changeset, :nickname, get_field(changeset, :email))
  end
end
```

## Assumptions

- `User` is an Ecto schema with `role` declared as `Ecto.Enum`. Its values are not in the input, so the list in the schema must match the roles the source uses.
- `Accounts.TaskSupervisor` is started in the application's supervision tree.
- The `users.email` column has a unique index. Without it, `unique_constraint/3` cannot catch a duplicate.
- The code was not compiled or run here, because `Repo`, `User`, and `Mailer` are not in the input.
