# Review: `Accounts.UserImporter`

## Findings

1. **The age cap never applies (line 15-17).** `age = 120` is set inside an `if`, and a variable rebound inside `if` stays inside it, so an age of 500 is saved as 500. Fix: cap the value with `min/2` in `parse_age/1`. Rule: "Assign the result of `if`, `case`, and `Enum` calls".

2. **The role becomes an atom from user input (line 8).** `role = String.to_atom(params["role"])` lets input create atoms, which are never freed, and a missing role crashes outside the `try`. Fix: keep the role as a string and let the schema cast it with `Ecto.Enum`, which accepts only the listed values. Rules: "Convert external strings to atoms with explicit clauses"; "Use `Ecto.Enum` for fields with a fixed set of atom values".

3. **Bad age text raises, then gets rescued (line 13).** `String.to_integer(params["age"])` raises on `"abc"` or `nil`, and the `rescue` below turns it into `:invalid`, so the caller cannot tell which field was wrong. Fix: `Integer.parse/1` returns `:error`, and the function returns `{:error, {:invalid_field, "age"}}`. Rule: "Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs".

4. **`rescue _ ->` hides every error (line 42-43).** It catches database failures and bugs as well as bad input, and reports them all as `:invalid`. Fix: remove the `try`; the non-raising calls return tuples, and real bugs raise. Rule: "Use `rescue` only around third-party code ... never `rescue _ ->` ... around a whole function".

5. **`&&` between booleans (line 21).** Both operands are booleans, so `and` states the intent. The `is_binary(email)` check is also dead code: line 12 already crashed on a `nil` email. Fix: the age check moves to `check_adult/1`, and the email check goes. Rule: "Use `and`, `or`, `not` when the operands are booleans".

6. **Check, then insert, with a bare struct (line 24-25).** `Repo.get_by(User, email: email) == nil` followed by `Repo.insert(user)` on a `%User{}` runs two steps, so two concurrent imports can both pass the check, and the struct insert skips validation. Fix: build a changeset that declares `unique_constraint(:email)`; the database rejects the duplicate and `Repo.insert/1` returns `{:error, changeset}`. Rules: "Validate input with changesets"; "Declare database constraints in the changeset (`unique_constraint/3`...)".

7. **The catch-all hides the reason (line 33-34).** `_ -> {:error, :insert_failed}` maps every failure to one atom, including validation errors the caller could act on. Fix: return the `Repo.insert/1` result unchanged. Rule: "Match every expected shape and let unexpected ones crash".

8. **Two overlapping options (line 27).** `opts[:notify] && !opts[:silent]` combines two booleans, and `silent` matters only when `notify` is set. Fix: drop `:silent` and keep `notify: true`. Rule: "Use one atom-valued field or option instead of overlapping booleans". This is a breaking change for callers that pass `silent:`; `Keyword.validate!/2` now rejects it with an error.

9. **Two return shapes from one function (line 31).** `if opts[:return_id], do: user.id, else: {:ok, user}` returns a bare integer in one mode and a tuple in the other. Fix: always return `{:ok, user}`; a caller that needs the ID reads `user.id`. Rule: "Give each function one return shape".

10. **Comments stand in for docs (lines 2, 5, 7, 48).** The module and function descriptions belong in `@moduledoc` and `@doc`, the options are undocumented, and lines 7 and 48 restate the code. Fix: add `@moduledoc`, a `@doc` with `## Options`, and delete the restating comments. Line 11 explains a reason and stays. Rule: "Comments explain why; documentation goes in `@moduledoc` and `@doc`".

11. **Single-step pipe and late key read (line 12).** `params["email"] |> String.downcase()` pipes one step, and the required keys are read in the body instead of the head. Fix: match `"email"` and `"age"` in the head and call `String.downcase/1` directly. Rules: "Do not pipe a single step"; "A function that parses string-keyed input matches the keys it requires in its head".

12. **Four nested levels in one function (line 15-41).** `if`, `if`, `if`, and `case` nest inside each other, and the reader has to track each condition at once. Fix: a `with` chain with one private function per step, each returning `{:ok, value}` or `{:error, reason}`. Rules: "Chain fallible steps with `with`"; "Keep functions short and at one level of detail".

13. **Unsupervised process (line 49).** `spawn(fn -> ... end)` starts a process that no supervisor restarts or tracks, so a crash is lost silently. Fix: `Task.Supervisor.start_child/2`. Rule: "Supervise every long-lived process". This needs an `Accounts.TaskSupervisor` in the application's supervision tree.

14. **The closure copies the whole user (line 49).** The closure calls `welcome_email(user)` inside the new process, so the whole `user` struct is copied for one field. Fix: build the text in the caller and capture only the text. Rule: "Send processes only the data they need".

15. **Access on a struct (line 53).** `user[:name]` raises `UndefinedFunctionError` because structs do not implement `Access`. This module also stores `nickname`, not `name`. Fix: `user.nickname`. Rule: "Read required keys with `map.key` or a pattern"; the struct note under that rule.

16. **Pipe into an anonymous function (line 55).** `greeting |> (fn text -> ... end).()` is hard to read and the rule forbids it. Fix: build the whole text in one interpolated string. Rule: "Do not pipe into an anonymous function call".

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
  Imports one user from string-keyed `params` and returns `{:ok, user}`.

  Ages above 120 are capped at 120. Returns `{:error, {:invalid_field, "age"}}`
  when the age is not an integer, `{:error, :underage}` when it is below 18,
  `{:error, changeset}` when the changeset is invalid or the email is taken,
  and `{:error, :invalid_payload}` when `"email"` or `"age"` is missing.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ [])

  def import_user(%{"email" => email, "age" => age} = params, opts) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, age} <- parse_age(age),
         :ok <- check_adult(age),
         {:ok, user} <- insert_user(params, email, age) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  def import_user(_params, _opts), do: {:error, :invalid_payload}

  defp parse_age(age) do
    case Integer.parse(age) do
      {value, ""} -> {:ok, min(value, @max_age)}
      _ -> {:error, {:invalid_field, "age"}}
    end
  end

  defp check_adult(age) when age >= @min_age, do: :ok
  defp check_adult(_age), do: {:error, :underage}

  defp insert_user(params, email, age) do
    # The provider lowercases addresses before its uniqueness check, so match it here
    email = String.downcase(email)

    attrs = %{
      email: email,
      age: age,
      role: params["role"],
      nickname: params["nickname"] || email
    }

    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp send_welcome(user) do
    text = welcome_text(user)

    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(text) end)
  end

  defp welcome_text(user), do: "Hi #{user.nickname}, welcome! Enjoy your account."
end
```

## Assumptions

- `User.changeset/2` casts `email`, `age`, `role`, and `nickname`, requires `email` and `role`, declares `unique_constraint(:email)`, and the `role` field uses `Ecto.Enum`. The module was not provided, so this is what the code needs from it.
- `Accounts.TaskSupervisor` is a `Task.Supervisor` in the application's supervision tree.
- `Mailer.deliver/1` takes the welcome text, as in the original.
- Callers that passed `silent:` or `return_id:` must change. `Keyword.validate!/2` raises on unknown options.

## Not verified

The improved code was not run through `mix format` or the compiler. Writing a scratch file outside this folder was denied, and the stdin check was rejected. Check it with `mix format --check-formatted` and `mix compile` in the project.
