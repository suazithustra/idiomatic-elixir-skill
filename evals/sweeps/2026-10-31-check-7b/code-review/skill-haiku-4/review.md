# Review: `Accounts.UserImporter`

Input: `code-review-input.ex`. Rules are from `idiomatic-elixir/SKILL.md` and its `references/processes.md` and `references/ecto-phoenix.md`.

## Findings

1. **Age cap never applies.** Rule: "Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it." The line `age = 120` inside `if age > 120 do` is local to the `if`, so an age of 200 is stored as 200. Fix: `age = min(age, @max_age)`.

2. **Welcome email crashes before it sends.** Rule: "Read required keys with `map.key` or a pattern; keep `map[:key]` for optional keys." The line `name = user[:name] || "there"` uses `Access` on a `User` struct, which raises `UndefinedFunctionError`. The crash happens inside the `spawn`, so no error reaches the caller and no email goes out. Fix: read `user.nickname`. The module never sets a `name` field, so confirm that `nickname` is the intended value.

3. **Input becomes an atom.** Rule: "Convert external strings to atoms with explicit clauses." The line `role = String.to_atom(params["role"])` lets any CSV or JSON row add an atom to the VM (virtual machine) atom table. A missing role also raises before the `try`. Fix: pass the role string to `User.changeset/2` and let an `Ecto.Enum` field cast it (see the assumption below).

4. **Blanket rescue hides bugs.** Rule: "Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs." The line `_ -> {:error, :invalid}` under `rescue` turns every exception in the function, including a typo in the code, into `:invalid`. Fix: remove the `try` and return tuples from small parsing functions.

5. **Bad age raises.** Rule: "Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs." The line `age = String.to_integer(params["age"])` raises on a non-numeric value, which is a normal input error. Fix: `Integer.parse/1` in `parse_age/1`, which returns a tuple.

6. **Duplicate check before insert, and a raw struct insert.** Rule: "Validate input with changesets" (`references/ecto-phoenix.md`). The lines `if Repo.get_by(User, email: email) == nil do` and `%User{email: email, ...}` check for the email first, then insert with no validation. Two imports of the same email at the same time both pass the check, and the database rejects the second with an exception. Fix: build the user with `User.changeset/2`, declare `unique_constraint(:email)`, and rely on the unique index. A duplicate then returns `{:error, changeset}`.

7. **Catch-all clause hides the insert error.** Rule: "Match every expected shape and let unexpected ones crash." The lines `_ -> {:error, :insert_failed}` throw away the reason a changeset gives. Fix: return the changeset error unchanged, as in the new `insert_user/1`.

8. **An option changes the return type.** Rule: "Give each function one return shape." The line `if opts[:return_id], do: user.id, else: {:ok, user}` makes `import_user/2` return an integer or a tuple. Fix: remove `:return_id`. Callers that need the ID read `user.id` from `{:ok, user}`. Any caller that passes `return_id:` must change.

9. **Overlapping booleans and unchecked options.** Rule: "Use one atom-valued field or option instead of overlapping booleans," and "Group related parameters" (check options with `Keyword.validate!/2`). The line `if opts[:notify] && !opts[:silent] do` makes `silent` matter only when `notify` is set, and any other option name is ignored without warning. Fix: keep `notify` and drop `silent`. `Keyword.validate!/2` then raises on unknown options. Callers that pass `silent:` must change. The rewrite does this with `Keyword.validate!(opts, notify: false)`.

10. **Bare `spawn`.** Rule: "Supervise every long-lived process" (`references/processes.md`). The line `spawn(fn -> Mailer.deliver(welcome_email(user)) end)` has no supervisor, so a crash is lost and nothing restarts it. Fix: `Task.Supervisor.start_child/2`, which needs `Accounts.TaskSupervisor` in the application's supervision tree. The rewrite also builds the email in the caller, so the closure captures only the string (rule: "Send processes only the data they need").

11. **One function does four jobs.** Rule: "Keep functions short and at one level of detail." `import_user/2` nests `if`, `case`, and `if` five levels deep. Fix: a `with` chain of small private functions, as in the rewrite. The rule "Chain fallible steps with `with`" applies here.

12. **Pipe into an anonymous function.** Rule: "Write pipelines that start with a value and read top to bottom," bullet "Do not pipe into an anonymous function call." The line `greeting |> (fn text -> text <> " Enjoy your account." end).()` is hard to read. Fix: a string interpolation, `"Hi #{user.nickname}, welcome! Enjoy your account."`.

13. **Pipe with one step.** Rule: "Write pipelines that start with a value and read top to bottom," bullet "Do not pipe a single step." The line `email = params["email"] |> String.downcase()` pipes one step. Fix: `String.downcase(params["email"])`. The rewrite calls `String.downcase/1` directly.

14. **Comments that restate the code, and no `@doc`.** Rule: "Comments explain why; documentation goes in `@moduledoc` and `@doc`." The comments `# This module imports...`, `# Import a single user...`, `# Get the role from params`, and `# send the email` restate the code or describe the module. `import_user/2` has no `@doc`. Fix: put the module description in `@moduledoc`, the function description and options in `@doc`, and delete the other comments. The comment `# The provider lowercases addresses...` explains a reason, so it stays.

## Improved version

The module below applies findings 1 to 14. It passes `mix format --check-formatted` and parses. It does not compile here, because `Accounts.User`, `Accounts.Repo`, `Mailer`, and `Accounts.TaskSupervisor` are not in this input.

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV (comma-separated values) or JSON source.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from string-keyed params.

  Returns `{:ok, user}` or `{:error, reason}`.

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

  defp parse_attrs(params) do
    with {:ok, email} <- string_field(params, "email"),
         {:ok, age} <- parse_age(params["age"]) do
      # The provider lowercases addresses before its uniqueness check, so match it here
      email = String.downcase(email)

      attrs = %{
        email: email,
        age: age,
        role: params["role"],
        nickname: params["nickname"] || email
      }

      {:ok, attrs}
    end
  end

  defp string_field(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
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

  defp insert_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp send_welcome(user) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

## Assumptions and behavior changes

The rewrite needs a `User.changeset/2` that the input does not show. This sketch is an assumption. The role values are placeholders.

```elixir
defmodule Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :age, :integer
    field :role, Ecto.Enum, values: [:admin, :editor, :viewer]
    field :nickname, :string
    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :age, :role, :nickname])
    |> validate_required([:email, :age, :role, :nickname])
    |> unique_constraint(:email)
  end
end
```

The database needs a unique index on `users.email` for `unique_constraint/3` to work.

Changed results for callers:
- A duplicate email returns `{:error, changeset}`, not `{:error, :invalid}`.
- An under-18 age returns `{:error, :too_young}`. Missing or non-numeric fields return `{:error, {:missing_field, key}}` or `{:error, {:invalid_field, key}}`.
- The `:return_id` and `:silent` options are removed. Passing either now raises from `Keyword.validate!/2`.
- The welcome email is sent under `Accounts.TaskSupervisor`, which must exist.
- The welcome email uses `user.nickname`. Confirm this is the intended name.
