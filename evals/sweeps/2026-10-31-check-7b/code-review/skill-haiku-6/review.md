# Review: `code-review-input.ex`

The module imports one user from string-keyed params. Its age cap never runs, a catch-all `rescue` hides every error, and the welcome email never sends. The findings below are ordered by severity. The improved version after them applies each one.

## Findings

1. **The age cap never applies.** Line 16, `age = 120`, sits inside an `if`. A variable bound inside `if` does not change the outer `age`, so an age of 150 is stored as 150. Rule: assigning the result of `if`, `case`, and `Enum` calls. Fix: `min(age, @max_age)` in `parse_age/1`.

2. **A catch-all `rescue` hides every failure.** Lines 42-43, `rescue` / `_ -> {:error, :invalid}`, turn any exception, including a bug, into the same error. Rule: "Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs." Fix: remove the `try` and use non-raising functions for the expected failures.

3. **Input becomes an atom.** Line 8, `role = String.to_atom(params["role"])`, lets any caller add atoms until the VM (virtual machine) limit of 1,048,576 is reached, and it raises on a missing role before the `try` starts. Rule: convert external strings to atoms with explicit clauses. Fix: declare `role` as an `Ecto.Enum` field and let `User.changeset/2` cast it (see the sketch below).

4. **Age parsing raises on bad input.** Line 13, `age = String.to_integer(params["age"])`, raises on `"abc"` or `nil`. Rule: use non-raising functions for expected failures. Fix: `parse_age/1` built on `Integer.parse/1`, returning tuples.

5. **Duplicate check before insert.** Line 24, `if Repo.get_by(User, email: email) == nil do`, is a lookup before an insert. Two requests can pass the check together and both insert. Rule: validate input with changesets, and declare the constraint with `unique_constraint/3`. Fix: `unique_constraint(:email)` in `User.changeset/2`; a duplicate then comes back as `{:error, changeset}`.

6. **A struct is inserted without validation.** Line 22, `user = %User{email: email, age: age, role: role, nickname: nickname}`, goes straight to `Repo.insert(user)` on line 25. Nothing is checked, and a constraint violation raises. Rule: validate input with changesets. Fix: `insert_user/2` builds the changeset with `User.changeset/2`.

7. **A wildcard clause hides new return values.** Line 33, `_ -> {:error, :insert_failed}`, turns every other result into one error. Rule: match every expected shape and let unexpected ones crash. Fix: the `with` in `import_user/2` passes the `{:error, changeset}` from `Repo.insert/1` through unchanged.

8. **Three failures share one reason.** Lines 37 and 40 return `{:error, :invalid}` for a duplicate email and for an age under 18, and the `rescue` does the same for anything else. A caller cannot tell them apart. Rule: different failures need different reasons. Fix: `{:error, :too_young}`, `{:error, {:invalid_field, "age"}}`, `{:error, {:missing_field, "age"}}`, and `{:error, changeset}` for the duplicate email.

9. **An option changes the return shape.** Line 31, `if opts[:return_id], do: user.id, else: {:ok, user}`, makes one function return either an integer or a tuple. Rule: give each function one return shape. Fix: drop `:return_id`; a caller reads `user.id` from `{:ok, user}`.

10. **Two overlapping booleans.** Line 27, `if opts[:notify] && !opts[:silent] do`, has a combination that makes no sense (`notify: true, silent: true`). Rule: use one atom-valued field or option instead of overlapping booleans. Fix: drop `:silent`, so `:notify` alone decides. This removes an option; any caller that passes `silent:` must stop doing so.

11. **Three nested `if` blocks and two `case` blocks.** Lines 15-41 nest the branches into a pyramid. Rule: branch with function clauses and guards before reaching for `if` or `cond`. Fix: a `with` over two private functions that each return a tuple.

12. **`&&` between booleans.** Line 21, `if is_binary(email) && age >= 18 do`, has two boolean operands, so the rule for `and` applies. The `is_binary/1` check can never be false at this point, because line 12 has already raised on a missing email. Rule: use `and`, `or`, `not` for booleans. Fix: removed; `parse_age/1` and the changeset check the input.

13. **A single-step pipe.** Line 12, `email = params["email"] |> String.downcase()`, pipes one call, and it raises on a missing email. Rule: do not pipe a single step. Fix: lowercasing moves into `User.changeset/2` with `update_change/3`, which skips a missing value.

14. **Options are neither checked nor documented.** Line 6, `def import_user(params, opts \\ []) do`, ignores a misspelled option such as `notfy: true` without a warning. Rule: group related parameters; check options with `Keyword.validate!/2` and document them under `## Options`. Fix: `Keyword.validate!(opts, notify: false)` and a `@doc` with an options section.

15. **A bare `spawn` with no supervisor.** Line 49, `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`, has no supervisor, so a crash is lost and nothing restarts it. The closure also captures the whole `user`. Rule (`references/processes.md`): supervise every long-lived process, and for fire-and-forget work use `Task.Supervisor.start_child/2`. Fix: `send_welcome/1` builds the email first and starts the task under `Accounts.TaskSupervisor`.

16. **Access syntax on a struct.** Line 53, `name = user[:name] || "there"`, raises `UndefinedFunctionError` because structs do not implement `Access`. The welcome email therefore never sends. The `User` struct also has no `name` field; the module sets `nickname`. Rule: read struct fields with `user.field` or a pattern. Fix: `user.nickname || "there"`.

17. **A pipe into an anonymous function.** Line 55, `greeting |> (fn text -> text <> " Enjoy your account." end).()`, is hard to read. Rule: do not pipe into an anonymous function call. Fix: one interpolated string in `welcome_email/1`.

18. **Comments that restate the code or document the module.** Lines 1-2 describe the module, line 5 restates the function head, line 7 restates `role = ...`, and line 48 restates the `spawn` line. Rule: comments explain why; documentation goes in `@moduledoc` and `@doc`. Fix: the module description moves to `@moduledoc`, the function description to `@doc`, and lines 5, 7, and 48 are deleted. Line 11 stays, because it gives a reason.

## Assumptions and behavior changes

- The improved code assumes `User.changeset/2` exists. The sketch below shows what it must do. The role values `[:admin, :editor, :viewer]` are placeholders; replace them with the real ones.
- `Accounts.TaskSupervisor` must be started in the application's supervision tree. `Mailer` is unchanged.
- The params are string-keyed and hold string values, as in the original. If a JSON source sends `age` as a number, `parse_age/1` needs an integer clause.
- Behavior changes: welcome emails now send; ages above 120 are stored as 120; a duplicate email returns a changeset error instead of `:invalid`; the `:silent` and `:return_id` options are removed.

## Improved version

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external source, such as a CSV or JSON file.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from string-keyed params.

  Returns `{:ok, user}` on success. On failure it returns `{:error, :too_young}`,
  `{:error, {:missing_field, "age"}}`, `{:error, {:invalid_field, "age"}}`, or
  `{:error, changeset}`, where the changeset names the failing field, such as a
  duplicate email.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, age} <- parse_age(params["age"]),
         {:ok, user} <- insert_user(params, age) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  defp parse_age(text) when is_binary(text) do
    case Integer.parse(text) do
      {age, ""} when age >= @min_age -> {:ok, min(age, @max_age)}
      {_age, ""} -> {:error, :too_young}
      {_age, _rest} -> {:error, {:invalid_field, "age"}}
      :error -> {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(_text), do: {:error, {:missing_field, "age"}}

  defp insert_user(params, age) do
    %User{}
    |> User.changeset(Map.put(params, "age", age))
    |> Repo.insert()
  end

  defp send_welcome(user) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user) do
    name = user.nickname || "there"
    "Hi #{name}, welcome! Enjoy your account."
  end
end
```

### `User.changeset/2` the improved version assumes

```elixir
defmodule Accounts.User do
  use Ecto.Schema

  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :age, :integer
    field :role, Ecto.Enum, values: [:admin, :editor, :viewer]
    field :nickname, :string
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :age, :role, :nickname])
    |> validate_required([:email, :age, :role])
    # The provider lowercases addresses before its uniqueness check, so match it here
    |> update_change(:email, &String.downcase/1)
    |> put_default_nickname()
    |> unique_constraint(:email)
  end

  defp put_default_nickname(changeset) do
    if get_field(changeset, :nickname) == nil do
      put_change(changeset, :nickname, get_field(changeset, :email))
    else
      changeset
    end
  end
end
```

The `unique_constraint/3` call needs a unique index on `users.email` in the migration.
