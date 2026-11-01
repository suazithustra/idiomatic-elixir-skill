# Review of `Accounts.UserImporter`

Two bugs come first: the age cap never takes effect, and any bad input is reported as `:invalid`. The remaining findings are idiom problems. I read `references/processes.md` and `references/ecto-phoenix.md` first, because the code uses `spawn` and `Repo`.

## Findings

1. **Bug: the age cap does nothing.** Rule: "Assign the result of `if`, `case`, and `Enum` calls". Line: `if age > 120 do age = 120 end`. The rebinding stays inside the `if`, so an age of 200 passes through unchanged. Fix: `min(age, @max_age)`, with the limit as a named attribute.

2. **`String.to_atom/1` on external input.** Rule: "Convert external strings to atoms with explicit clauses". Line: `role = String.to_atom(params["role"])`. Anyone who controls the input can exhaust the atom table. It also crashes on a missing role, and the crash is hidden by the `rescue`, but only because the call sits outside the `try`. Fix: declare `role` as an `Ecto.Enum` field, so the changeset casts and rejects unknown values.

3. **`try/rescue` used to produce a tuple.** Rule: "Return `{:ok, value}` or `{:error, reason}` for expected failures". Lines: `try do ... rescue _ -> {:error, :invalid} end`. This swallows every exception, including real bugs such as a failed `Repo` call. Fix: remove it. Use `Integer.parse/1` instead of `String.to_integer/1`.

4. **One error, `:invalid`, for different failures.** Rule: "Match every expected shape and let unexpected ones crash". Lines: both `{:error, :invalid}` returns. A caller cannot tell a duplicate email from an underage user or a malformed age. Fix: `{:error, {:invalid_field, "age"}}`, `{:error, :invalid_params}`, and `{:error, changeset}` for validation and constraint errors.

5. **Catch-all `_ ->` after `Repo.insert/1`.** Rule: "Match every expected shape". Line: `_ -> {:error, :insert_failed}`. It discards the changeset, which says what went wrong. Fix: return `{:error, changeset}` unchanged by chaining the insert in a `with`.

6. **Required keys read with `params["..."]`.** Rules: "Match the required keys of string-keyed input in a function head" and "Read required keys with `map.key` or a pattern". Lines: `params["email"]`, `params["age"]`, `params["role"]`. A missing key gives `nil`, which then fails inside `String.downcase/1` or `String.to_integer/1` and is hidden by the `rescue`. Fix: match `%{"email" => email, "age" => age, "role" => role}` in the head, with a fallback clause returning `{:error, :invalid_params}`.

7. **Manual validation instead of a changeset.** Rule (`ecto-phoenix.md`): "Validate input with changesets". Lines: `%User{email: email, ...}` passed to `Repo.insert/1`, and `age >= 18`. Fix: `User.changeset/2` with `cast/3`, `validate_required/2` and `validate_number/3`. The age floor moves there.

8. **Lookup before insert.** Rule (`ecto-phoenix.md`): "`unique_constraint/3`". Line: `Repo.get_by(User, email: email) == nil`. Two concurrent imports of the same email can both pass the check, and the second insert then fails or creates a duplicate. Fix: `unique_constraint(:email)` in the changeset, and the database unique index decides.

9. **`&&` and `!` on booleans.** Rule: "Use `and`, `or`, `not` when the operands are booleans". Line: `is_binary(email) && age >= 18`. The `is_binary(email)` check also comes after `String.downcase(email)`, which would already have raised. Fix: `is_binary(email)` as a guard in the function head.

10. **Overlapping booleans `:notify` and `:silent`.** Rule: "Use one atom-valued field or option instead of overlapping booleans". Line: `opts[:notify] && !opts[:silent]`. `notify: true, silent: true` has no sensible meaning. Fix: keep only `:notify`, defaulting to `false`, and check it with `Keyword.validate!/2`.

11. **Option `:return_id` changes the return shape.** Rule: "Give each function one return shape". Line: `if opts[:return_id], do: user.id, else: {:ok, user}`. Fix: always return `{:ok, user}`. A caller who wants the id reads `user.id`.

12. **Nested `if`/`case`/`if` four levels deep.** Rule: "Keep functions short and at one level of detail". `import_user/2` mixes parsing, validation, the database and notification. Fix: a `with` chain with a small private function per step.

13. **Unsupervised `spawn/1`.** Rule (`processes.md`): "Supervise every long-lived process" and "Fire-and-forget work". Line: `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`. A crash in the delivery is not tied to any supervisor. Fix: `Task.Supervisor.start_child/2`. The closure also copies the whole `user`, so I build the email first and capture only that. This needs `{Task.Supervisor, name: Accounts.TaskSupervisor}` in the application's supervision tree.

14. **Access syntax on a struct.** Rule: "Read required keys with `map.key`". Line: `user[:name]`. `%User{}` does not implement `Access`, so this raises `UndefinedFunctionError` on every welcome email. Also, `User` is built here with `nickname`, not `name`. Fix: `user.nickname`. If `User` really has a `name` field, change it back.

15. **Pipe into an anonymous function, and string concatenation.** Rules: "Do not pipe into an anonymous function call" and "Write pipelines that start with a value". Lines: `greeting |> (fn text -> ... end).()` and the `<>` chain. Fix: one interpolated string.

16. **Comments restate the code, and there are no docs.** Rule: "Comments explain why; documentation goes in `@moduledoc` and `@doc`". Lines: `# Get the role from params`, `# send the email`, and the plain comments above the module and `import_user/2`. Fix: `@moduledoc` and `@doc` with an `## Options` section. The comment about the provider lowercasing addresses explains a reason, so I kept it.

17. **`Mailer` is not aliased.** `Mailer.deliver/1` is a bare top-level module, which breaks "Put every module under the top-level namespace of its own application". I assumed `Accounts.Mailer`. Change it if the mailer lives elsewhere.

18. **Ordering of module setup.** `alias Accounts.{Repo, User}` is fine, but one alias per line matches the skill's example and makes diffs smaller.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from external CSV or JSON params.
  """

  alias Accounts.Mailer
  alias Accounts.Repo
  alias Accounts.User

  @max_age 120

  @doc """
  Imports a single user from string-keyed params.

  Requires the keys `"email"`, `"age"` and `"role"`; `"nickname"` is optional and
  defaults to the email. Ages above #{@max_age} are lowered to #{@max_age}.

  Returns `{:ok, user}`, `{:error, :invalid_params}` when a required key is missing,
  `{:error, {:invalid_field, "age"}}` when the age is not an integer, or
  `{:error, changeset}` when validation or the unique email constraint fails.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ [])

  def import_user(%{"email" => email, "age" => age, "role" => role} = params, opts)
      when is_binary(email) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, age} <- parse_age(age),
         {:ok, user} <- insert_user(params, email, age, role) do
      if opts[:notify], do: send_welcome(user)

      {:ok, user}
    end
  end

  def import_user(_params, _opts), do: {:error, :invalid_params}

  defp parse_age(text) when is_binary(text) do
    case Integer.parse(text) do
      {age, ""} ->
        {:ok, min(age, @max_age)}

      {_age, _rest} ->
        {:error, {:invalid_field, "age"}}

      :error ->
        {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(_age), do: {:error, {:invalid_field, "age"}}

  defp insert_user(params, email, age, role) do
    # The provider lowercases addresses before its uniqueness check, so match it here
    email = String.downcase(email)

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

  defp send_welcome(user) do
    email = welcome_email(user)

    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

Supporting change in `Accounts.User` (not in the reviewed file):

```elixir
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
  |> validate_number(:age, greater_than_or_equal_to: 18)
  |> unique_constraint(:email)
end
```

The `Ecto.Enum` values above are placeholders; use the roles the application actually has. I did not compile or run this, because the module depends on `Accounts.Repo`, `Accounts.User` and `Accounts.Mailer`, which are not in the input.
