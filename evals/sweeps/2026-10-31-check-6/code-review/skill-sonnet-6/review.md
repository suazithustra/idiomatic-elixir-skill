# Review of `Accounts.UserImporter`

The module has two bugs that change results: the age cap never applies, and the invalid-input check runs after `String.downcase/1` has already crashed. It also builds by hand what Ecto provides (validation, a uniqueness check). Findings follow, then the improved code.

## Findings

1. **Age cap does nothing** (rule: assign the result of `if`; rebinding inside a block does not escape it). `if age > 120 do age = 120 end` rebinds `age` only inside the `if`. Ages above 120 pass through uncapped. Fix: `age: min(age, @max_age)`.

2. **`String.to_atom/1` on external input** (rule: convert external strings to atoms with explicit clauses). `role = String.to_atom(params["role"])` can exhaust the atom table, and it raises on a missing role, outside the `try`. Fix: `parse_role("admin")`, `parse_role("member")`, and a catch-all clause returning `{:error, {:invalid_field, "role"}}`. The role names are my assumption; use the real ones.

3. **`try/rescue _ ->` turns bugs into `{:error, :invalid}`** (rule: no `try/rescue` to get a tuple; never `rescue _`). It hides a missing `"email"`, a non-numeric age, and real bugs alike. Fix: use `Integer.parse/1` and `Map.fetch/2`, and drop the `try`.

4. **Checks run in the wrong order and are partly dead** (`params["email"] |> String.downcase()`, `is_binary(email) && age >= 18`). A missing email makes `String.downcase(nil)` raise before `is_binary/1` is reached, so that check can never be false. Fix: validate each field in its own step (`string_field/2`) before using it.

5. **Required keys read with `params["key"]`, one generic error** (rules: required keys; parse external data at the boundary; different failures need different reasons). Every failure is `{:error, :invalid}`, so a caller cannot tell a missing email from a bad age. Fix: `string_field/2` and `integer_field/2` chained with `with`, returning `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}`. `params["nickname"]` stays, since it is optional.

6. **Unvalidated struct passed to `Repo.insert/1`** (ecto-phoenix: validate input with changesets). `%User{email: ..., age: ...}` skips casting and validation, and the age >= 18 check is written by hand. Fix: `%User{} |> User.changeset(attrs) |> Repo.insert()`, with the age check as `validate_number/3` in the changeset.

7. **Lookup before insert** (rule: use `unique_constraint/3`). `Repo.get_by(User, email: email) == nil` races: two imports of the same email can both pass the check, and the second insert then raises or duplicates. Fix: `unique_constraint(:email)` in `User.changeset/2` backed by a unique index; a duplicate returns `{:error, changeset}`.

8. **`_ ->` clause after `{:ok, user}` discards the reason**. `{:error, :insert_failed}` hides the changeset errors. Fix: return the `{:error, changeset}` unchanged by chaining with `with`.

9. **Nested `if`/`case`/`if` inside `try`** (rule: keep functions short; one level of detail). Replaced by a flat `with` of small steps.

10. **Overlapping booleans `notify`/`silent`** (rule: one atom-valued field instead of overlapping booleans). `notify: true, silent: true` is contradictory. Fix: a single `:notify` option, validated with `Keyword.validate!/2` and documented under `## Options`.

11. **`:return_id` changes the return shape** (rule: one return shape per function). It returns `user.id` or `{:ok, user}`. Fix: always return `{:ok, user}`; callers read `user.id`. This removes an option, so check callers.

12. **`opts[:notify] && !opts[:silent]`** (rule: `and`/`or`/`not` for booleans). Gone with finding 10. The remaining `is_binary(email) && age >= 18` is replaced by the checks in findings 4 and 6.

13. **Unsupervised `spawn/1`** (processes: supervise every long-lived process; use `Task.Supervisor.start_child/2` for fire-and-forget). A crash in `Mailer.deliver/1` goes unreported and the work is lost on shutdown. Fix: `Task.Supervisor.start_child(@task_supervisor, ...)`. `Accounts.TaskSupervisor` must be in the supervision tree. The email is built before the closure so the task copies only the message, not the whole user (processes: send processes only the data they need).

14. **`user[:name]` on a struct** (rule: structs do not implement `Access`). It raises `UndefinedFunctionError`, so the welcome email never gets sent. Fix: read a field with a dot. `User` as shown has no `name` field, so I used `user.nickname`; change it if `User` has a name.

15. **Anonymous-function pipe** (rule: do not pipe into an anonymous function). `greeting |> (fn text -> ... end).()` is replaced by one interpolated string.

16. **Comments restate the code or sit in place of docs** (rule: comments explain why; `@moduledoc`/`@doc`). Removed `# Get the role from params`, `# send the email`, and the two header comments; added `@moduledoc`, `@doc` with `## Options`, and `@spec`. Kept the reason for lowercasing the email, now in the `@doc`, and one comment on what `User.changeset/2` must do.

17. **Magic numbers 120 and 18**. 120 is now `@max_age`. 18 moves to the changeset.

18. **Unaliased `Mailer`; alias grouping**. `Mailer` was used without an alias and the `{Repo, User}` multi-alias is not one-per-line. I added `alias Accounts.Mailer`, which assumes that module name.

19. **Pipe shape** (rule: pipelines). `params["email"] |> String.downcase()` was a single-step pipe. It is now `String.downcase(email)`.

## Assumptions the rewrite needs

- `Accounts.User.changeset/2` exists, casts `email`, `age`, `role`, `nickname`, requires them, applies `validate_number(:age, greater_than_or_equal_to: 18)`, and has `unique_constraint(:email)` with a unique database index. `Accounts.User` needs a `@type t`.
- Roles are `admin` and `member`; adjust `parse_role/1`.
- `Accounts.Mailer` and `Accounts.TaskSupervisor` exist.

## Verification

`mix format --check-formatted` passes on the file. It does not compile on its own, because `Accounts.User` is defined outside this file. I did not run it against a real project.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from string-keyed params, such as rows decoded from a CSV or JSON source.
  """

  alias Accounts.Mailer
  alias Accounts.Repo
  alias Accounts.User

  @max_age 120
  @task_supervisor Accounts.TaskSupervisor

  @doc """
  Imports a single user from string-keyed `params`.

  `params` must hold `"email"`, `"age"` and `"role"` as strings; `"nickname"` is optional
  and defaults to the email. Emails are lowercased to match the provider's uniqueness
  check, and ages above #{@max_age} are set to #{@max_age}.

  Returns `{:ok, user}`, `{:error, {:missing_field, key}}`, `{:error, {:invalid_field, key}}`
  or `{:error, changeset}` when validation fails, including a duplicate email.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, term()}
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, attrs} <- parse_params(params),
         {:ok, user} <- insert_user(attrs) do
      if opts[:notify], do: send_welcome(user)

      {:ok, user}
    end
  end

  defp parse_params(params) do
    with {:ok, email} <- string_field(params, "email"),
         {:ok, age} <- integer_field(params, "age"),
         {:ok, role} <- role_field(params) do
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
      {:ok, value} when is_binary(value) ->
        {:ok, value}

      {:ok, _value} ->
        {:error, {:invalid_field, key}}

      :error ->
        {:error, {:missing_field, key}}
    end
  end

  defp integer_field(params, key) do
    with {:ok, text} <- string_field(params, key) do
      case Integer.parse(text) do
        {integer, ""} ->
          {:ok, integer}

        {_integer, _rest} ->
          {:error, {:invalid_field, key}}

        :error ->
          {:error, {:invalid_field, key}}
      end
    end
  end

  defp role_field(params) do
    with {:ok, text} <- string_field(params, "role") do
      parse_role(text)
    end
  end

  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("member"), do: {:ok, :member}
  defp parse_role(_other), do: {:error, {:invalid_field, "role"}}

  # `User.changeset/2` casts the attrs, requires them, checks `age >= 18`, and
  # declares `unique_constraint(:email)`, so a duplicate comes back as `{:error, changeset}`.
  defp insert_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp send_welcome(user) do
    email = welcome_email(user)

    Task.Supervisor.start_child(@task_supervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```
