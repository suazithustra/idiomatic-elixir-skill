# Review: Accounts.UserImporter

## Findings

1. Line 8, `role = String.to_atom(params["role"])`, turns any string from the import file into an atom. Atoms are never freed and the VM (virtual machine) has a fixed atom limit, so a large or hostile file can crash the node. The call also sits outside the `try`, so a missing role raises. Rule: "Convert external strings to atoms with explicit clauses". Fix: declare `role` as an `Ecto.Enum` field in the schema and let the changeset cast the string; an unknown value becomes a changeset error.

2. Lines 42-43, `rescue _ -> {:error, :invalid}`, wrap the whole function, so any bug (a typo, a wrong call) is reported as bad input. Rule: "rescue the specific exception, never `rescue _ ->`". Fix: remove the `try`. The new code parses input into tuples and does not raise on bad input.

3. Line 13, `String.to_integer(params["age"])`, raises on text such as `"abc"` and on a missing key. Rule: "Call the non-raising version" (here `Integer.parse/1`). Fix: `parse_integer/2` matches `{integer, ""}` and returns `{:error, {:invalid_field, "age"}}` otherwise.

4. Lines 15-17, `age = 120` inside an `if`, does not change the outer `age`, because a variable rebound inside a block does not escape it. Ages above 120 are stored as given. Rule: "Assign the result of `if`, `case`, and `Enum` calls". Fix: `age: min(age, @max_age)`.

5. Lines 22-25 build a raw `%User{}`, check for an existing email with `Repo.get_by`, and then call `Repo.insert/1`. Nothing is validated, and two imports racing on the same email can both pass the check. Rule (references/ecto-phoenix.md): "Cast and validate external input with `Ecto.Changeset`" and "Declare database constraints in the changeset (`unique_constraint/3`, ...) so a violation returns `{:error, changeset}` instead of raising." Fix: `User.changeset(%User{}, attrs)` piped to `Repo.insert/1`, with `unique_constraint(:email)` in the changeset.

6. Lines 25-41 collapse every failure into one of two reasons. `_ -> {:error, :insert_failed}` catches every return value, and both `{:error, :invalid}` clauses hide whether the age, the email, or a duplicate caused the failure. Rule: "Match every expected shape and let unexpected ones crash", and "Different failures need different reasons too". Fix: a `with` passes the changeset error through, and field errors use `{:missing_field, key}` or `{:invalid_field, key}`.

7. Line 31, `if opts[:return_id], do: user.id, else: {:ok, user}`, makes one option change the return shape. Rule: "Give each function one return shape". Fix: removed. Callers read `user.id` from `{:ok, user}`. Any caller that passes `return_id: true` must change.

8. Lines 6 and 27 read `opts` with `opts[:notify]` and `opts[:silent]`. The two options overlap: `notify: true, silent: true` has no defined meaning. The module also uses `&&` and `!` on booleans and never checks option names, so a typo is ignored. Rules: "Use one atom-valued field or option instead of overlapping booleans", "Use `and`, `or`, `not` when the operands are booleans", and "check them with `Keyword.validate!/2`". Fix: one option `welcome: :email | :none`, validated with `Keyword.validate!/2`. Callers that pass `notify` or `silent` must change.

9. Line 12, `params["email"] |> String.downcase()`, pipes a single step, and raises `FunctionClauseError` on a missing email before the `is_binary/1` check on line 21 runs. Rule: "Do not pipe a single step". Fix: `fetch_string/2` checks that the key exists and holds a string, and returns `{:error, {:missing_field, "email"}}` otherwise.

10. Line 53, `user[:name]`, raises `UndefinedFunctionError`, because structs do not implement `Access`. The `name` field is also not one of the fields this module sets (`email`, `age`, `role`, `nickname`). Rule: "Structs do not implement `Access`: `user[:name]` raises `UndefinedFunctionError`". Fix: `user.nickname`, which is set on every import.

11. Line 55, `greeting |> (fn text -> text <> " Enjoy your account." end).()`, pipes into an anonymous function. Rule: "Do not pipe into an anonymous function call". Fix: one interpolated string.

12. Line 49, `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`, starts a process that no supervisor owns, so a crash is not recorded and nothing restarts it. The closure also captures all of `user`. Rules (references/processes.md): "Supervise every long-lived process" and "Send processes only the data they need". Fix: build the email in the caller and start the work under `Task.Supervisor.start_child/2`.

13. Lines 2, 5, 7, and 48 are comments that describe the module or restate the next line. Rules: "Document modules and public functions with `@moduledoc` and `@doc`, not with comments above them" and "Delete comments that restate the code". Fix: a `@moduledoc` and a `@doc` on `import_user/2`; the other comments go. Line 11 explains a reason the code cannot show, so it stays.

14. Lines 10-45 nest a `try`, two `if`s, a `case`, and a second `if`, which makes the success path hard to follow. Rule: "Keep functions short and at one level of detail", and "Chain fallible steps with `with`; normalize each step's error in a small private function". Fix: a `with` over `user_attrs/1` and `Repo.insert/1`, with each check in its own private function.

## Improved version

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.{Repo, User}

  @max_age 120

  @doc """
  Imports one user from string-keyed params.

  Returns `{:ok, user}` or `{:error, reason}`. Checks that need the schema
  (role, minimum age, unique email) run in `User.changeset/2`; their failures
  come back as `{:error, changeset}`.

  ## Options

    * `:welcome` - `:email` sends a welcome email after the insert, `:none`
      sends nothing. Defaults to `:none`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, welcome: :none)

    with {:ok, attrs} <- user_attrs(params),
         {:ok, user} <- Repo.insert(User.changeset(%User{}, attrs)) do
      maybe_send_welcome(user, opts[:welcome])
      {:ok, user}
    end
  end

  defp user_attrs(params) do
    with {:ok, email} <- fetch_string(params, "email"),
         {:ok, age} <- parse_age(params) do
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

  defp parse_age(params) do
    with {:ok, text} <- fetch_string(params, "age") do
      parse_integer(text, "age")
    end
  end

  defp parse_integer(text, field) do
    case Integer.parse(text) do
      {integer, ""} -> {:ok, integer}
      {_integer, _rest} -> {:error, {:invalid_field, field}}
      :error -> {:error, {:invalid_field, field}}
    end
  end

  defp fetch_string(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp maybe_send_welcome(user, :email) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp maybe_send_welcome(_user, :none), do: :ok

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

## Assumptions to confirm

- `User.changeset/2` exists. It casts `email`, `age`, `role`, and `nickname`; requires `email` and `age`; checks `validate_number(:age, greater_than_or_equal_to: 18)`; and calls `unique_constraint(:email)`.
- The `role` field is declared as `field :role, Ecto.Enum, values: [...]` with the roles the app defines.
- `Accounts.TaskSupervisor` is started in the application's supervision tree.
- `Mailer.deliver/1` takes the message struct it expects. The original passed the string returned by `welcome_email/1`. If the mailer needs a struct, `welcome_email/1` must build one.
- Numeric JSON values such as `"age": 30` are rejected as `{:invalid_field, "age"}`. The original rejected them too, through its `rescue`. If the source sends integers, extend `parse_integer/2` to accept them.
- Callers that pass `return_id`, `notify`, or `silent` need the changes described in findings 7 and 8.
