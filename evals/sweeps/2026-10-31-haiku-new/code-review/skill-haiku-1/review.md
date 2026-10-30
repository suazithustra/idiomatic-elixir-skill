# Review: `Accounts.UserImporter`

The module stores users aged over 120 with their real age, and every welcome email attempt crashes. The rest of the problems are error handling that hides failures, and code that builds atoms and queries by hand where Elixir has a plain function or an Ecto (Elixir's database library) changeset for the job. The improved version follows.

## Findings

1. **Age cap never applies.** `if age > 120 do age = 120 end` (line 15) rebinds `age` inside the `if`, and the new value does not leave the block. A value of 200 is stored as 200. Rule: "Assign the result of `if`, `case`, and `Enum` calls." Fix: `check_age/1` returns `min(age, @max_age)`.

2. **Welcome email crashes on every send.** `name = user[:name] || "there"` (line 53) uses Access syntax on a `%User{}` struct, which raises, and the struct has no `name` field anyway. Rule: "Structs do not implement `Access`." Fix: read `user.nickname`, which the importer always sets (it falls back to the email), so the `"there"` fallback goes.

3. **A catch-all `rescue` hides every bug.** `rescue _ -> {:error, :invalid}` (lines 42–43) wraps the whole function, so a typo, a `nil` input, or a database error all become "invalid". Rule: "never `rescue _ ->` around a whole function." Fix: each field is parsed with a non-raising call that returns a tagged error, and the `try` is removed.

4. **Raising parsers on user input.** `String.to_integer(params["age"])` (line 13) raises on bad input, and `params["email"] |> String.downcase()` (line 12) raises on `nil`. Rule: "Call the non-raising version," and "Do not pipe a single step." Fix: `Integer.parse/1` in `parse_age/1`, and `String.downcase/1` called directly after a `parse_email/1` clause matches a binary.

5. **Atoms built from external input.** `role = String.to_atom(params["role"])` (line 8) creates an atom from input, which the VM never frees, and it sits outside the `try`, so a missing role crashes the import. Rule: "Convert external strings to atoms with explicit clauses." Fix: `parse_role/1` lists the accepted values.

6. **Lookup before insert.** `Repo.get_by(User, email: email) == nil` (line 24) checks for a duplicate in a separate query, so two imports of the same email can both pass the check. Rule: declare the constraint in the changeset with `unique_constraint/3`. Fix: `User.changeset/2` declares `unique_constraint(:email)`, and a duplicate comes back as `{:error, changeset}`.

7. **Struct inserted without validation.** `user = %User{email: email, age: age, role: role, nickname: nickname}` (line 22) goes straight to `Repo.insert/1`. Rule: "Cast and validate external input with `Ecto.Changeset`." Fix: `%User{role: role} |> User.changeset(attrs) |> Repo.insert()`. The role is set on the struct, not cast, so input cannot choose it.

8. **Catch-all insert clause.** `_ -> {:error, :insert_failed}` (line 33) turns every other return value into one error. Rule: "Match every expected shape." Fix: `{:error, changeset}` passes through the `with` unchanged.

9. **Return shape depends on an option.** `if opts[:return_id], do: user.id, else: {:ok, user}` (line 31) returns a bare integer in one mode and a tuple in the other. Rule: "Give each function one return shape." Fix: `:return_id` is removed. Callers read `user.id` from `{:ok, user}`.

10. **Two booleans that overlap.** `opts[:notify] && !opts[:silent]` (line 27) lets `notify: true, silent: true` mean "do not send", which is the same as `notify: false`. Rule: "Use one atom-valued field or option instead of overlapping booleans." Fix: `:silent` is removed. `:notify` alone decides whether the email is sent.

11. **Errors lose their reason.** Underage, duplicate email, bad age, and bad email all return `{:error, :invalid}` (lines 37, 40). Rule: "Use atoms, tagged tuples, or exception structs as error reasons." Fix: `{:invalid_field, key}` for input that fails to parse, `:underage` for age under 18, and the changeset for validation and duplicate errors.

12. **Bare `spawn`.** `spawn(fn -> Mailer.deliver(welcome_email(user)) end)` (line 49) runs outside any supervisor, so nothing restarts or tracks it. Rule: "Supervise every long-lived process." Fix: `Task.Supervisor.start_child/2` under `Accounts.TaskSupervisor`.

13. **Pipe into an anonymous function.** `greeting |> (fn text -> text <> " Enjoy your account." end).()` (line 55) is a pipe into a `fn` call, and the `name` and `greeting` bindings are used once each. Rule: "Do not pipe into an anonymous function call." Fix: one interpolated string.

14. **One function holds every step.** `import_user/2` nests a `try`, three `if`s, a `case`, and a second `if`, so the success path is hard to see. Rule: "Chain fallible steps with `with`" and "Keep functions short and at one level of detail." Fix: a `with` chain over small `parse_*` functions, with the public function first.

15. **Comments restate the code, and the docs are comments.** `# Get the role from params` and `# send the email` say what the code already shows, and the module and function descriptions are comments instead of `@moduledoc` and `@doc`. Rule: "Comments explain why; documentation goes in `@moduledoc` and `@doc`." Fix: `@moduledoc` and `@doc` replace the header comments. The lowercasing comment stays, because it gives the reason for the `downcase` call.

16. **`&&` on values that are already known to be booleans.** `if is_binary(email) && age >= 18` (line 21) uses `&&`, and the `is_binary` check runs after `downcase`, which would already have raised on `nil`. Rule: "Use `and`, `or`, `not` when the operands are booleans." Fix: the binary check moves into a guard on `parse_email/1`, and the age check is `check_age/1`.

## Improved version

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV (comma-separated values) or JSON source.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from the given params.

  Returns `{:ok, user}` on success. On failure returns `{:error, reason}`, where
  `reason` is `{:invalid_field, key}`, `:underage`, or an `Ecto.Changeset` that
  lists the validation errors, such as a duplicate email.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    with {:ok, email} <- parse_email(params),
         {:ok, age} <- parse_age(params),
         {:ok, role} <- parse_role(params),
         attrs = %{email: email, age: age, nickname: params["nickname"] || email},
         {:ok, user} <- insert_user(role, attrs) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  defp parse_email(%{"email" => email}) when is_binary(email) do
    # The provider lowercases addresses before its uniqueness check, so match it here
    {:ok, String.downcase(email)}
  end

  defp parse_email(_params), do: {:error, {:invalid_field, "email"}}

  defp parse_age(%{"age" => age}) when is_binary(age) do
    case Integer.parse(age) do
      {value, ""} -> check_age(value)
      {_value, _rest} -> {:error, {:invalid_field, "age"}}
      :error -> {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(_params), do: {:error, {:invalid_field, "age"}}

  defp check_age(age) when age < @min_age, do: {:error, :underage}
  defp check_age(age), do: {:ok, min(age, @max_age)}

  defp parse_role(%{"role" => "admin"}), do: {:ok, :admin}
  defp parse_role(%{"role" => "member"}), do: {:ok, :member}
  defp parse_role(_params), do: {:error, {:invalid_field, "role"}}

  defp insert_user(role, attrs) do
    %User{role: role}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp send_welcome(user) do
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn ->
      Mailer.deliver(welcome_email(user))
    end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

## Behavior changes and assumptions

Callers see different results in four places. Errors are now `{:invalid_field, key}`, `:underage`, or a changeset, instead of `:invalid` and `:insert_failed`. The `:return_id` and `:silent` options are removed. The welcome email now sends, where before it crashed.

The rewrite assumes four things that the code under review does not show. `User.changeset/2` casts `email`, `age`, and `nickname`, and declares `unique_constraint(:email)`, with a matching unique index in the database. The accepted roles are `"admin"` and `"member"`; replace them with the values the `User` schema accepts. `Accounts.TaskSupervisor` is started in the application's supervision tree. `Mailer.deliver/1` accepts the string that `welcome_email/1` returns, as the original code also assumed; if it needs a mail struct, `welcome_email/1` must build one.

The improved version has not been compiled or run with `mix format`, because a permission request to check for Elixir was declined.
