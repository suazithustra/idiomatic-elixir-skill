# Review: `code-review-input.ex` (`Accounts.UserImporter`)

## Findings

1. The age cap never applies (a bug). Line 15–17, `if age > 120 do age = 120 end`: the new `age` exists only inside the `if`, so the outer `age` keeps its original value and ages above 120 are stored as given. Fix: cap the value in the changeset with `update_change(:age, &min(&1, 120))`. Rule: "Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it."

2. A rescue wraps the whole function. Lines 10 and 42–43, `try do ... rescue _ -> {:error, :invalid} end`, turn any bug, including a typo, into "invalid". Fix: remove the `try`; use non-raising calls and changeset errors. Rule: "never `rescue _ ->` around a whole function."

3. Input becomes an atom. Line 8, `role = String.to_atom(params["role"])`, creates an atom from outside input. Atoms are never garbage-collected, so a stream of unique role names can exhaust the atom table and crash the node. A missing role also raises here, outside the `try`. Fix: declare `field :role, Ecto.Enum` in the schema; the changeset converts the string and rejects unknown values. Rule: "Convert external strings to atoms with explicit clauses."

4. Age parse raises on bad input. Line 13, `age = String.to_integer(params["age"])`, raises on text such as "abc", and the rescue turns that into `{:error, :invalid}` with no reason. Fix: let the changeset cast the age and report the `:age` field. Rule: "Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs."

5. Email is downcased by a single-step pipe. Line 12, `params["email"] |> String.downcase()`, pipes one step and raises when the email is `nil`. Fix: `update_change(:email, &String.downcase/1)` in the changeset, which runs only on a value that is present. Rule: "Do not pipe a single step."

6. The struct is inserted without validation. Lines 22 and 25, `%User{email: ...}` passed to `Repo.insert(user)`, skip every check. Fix: `%User{} |> User.changeset(params) |> Repo.insert()`. Rule: "Validate input with changesets."

7. Duplicate check before insert. Line 24, `Repo.get_by(User, email: email) == nil`, checks for a duplicate and then inserts. Two requests can both pass the check and both insert. Fix: `unique_constraint(:email)` in the changeset; the database enforces the rule and the violation comes back as `{:error, changeset}`. Rule: "Declare database constraints in the changeset." The `== nil` comparison is part of the same problem.

8. Catch-all clause hides the error. Line 33, `_ -> {:error, :insert_failed}`, drops the changeset that explains the failure. Fix: remove the clause; the `{:error, changeset}` from `Repo.insert/1` passes through. Rule: "Match every expected shape and let unexpected ones crash."

9. Three different failures share one reason. Lines 37, 40 and 43 all return `{:error, :invalid}`, so a caller cannot tell a duplicate email from a missing field or an underage user. Fix: return `{:error, changeset}`, whose `errors` name the field. Rule: "Different failures need different reasons too."

10. An option changes the return shape. Line 31, `if opts[:return_id], do: user.id, else: {:ok, user}`, returns a bare integer in one mode and a tuple in the other. Fix: remove the option; callers read `user.id` from `{:ok, user}`. Rule: "Give each function one return shape."

11. Two booleans overlap. Line 27, `opts[:notify] && !opts[:silent]`, makes `silent` meaningful only when `notify` is true. Fix: remove `:silent`; `notify: true` alone sends the welcome email. Rule: "Use one atom-valued field or option instead of overlapping booleans."

12. Options are not checked. Line 6, `def import_user(params, opts \\ [])`, accepts any keyword list, so a typo such as `notfy: true` is ignored without a warning. Fix: `opts = Keyword.validate!(opts, notify: false)`. Rule: "check them with `Keyword.validate!/2`."

13. Four levels of nesting. Lines 15–41 nest an `if`, an `if`, a `case` and another `if` inside a `try`. Fix: the changeset holds the checks, and the public function becomes a `with` of two steps. Rule: "Keep functions short and at one level of detail."

14. Boolean operator where `and` fits. Line 21, `is_binary(email) && age >= 18`, has two boolean operands. Fix: the changeset checks `age` with `validate_number/3` and `email` with `validate_required/2`, so the line goes. Rule: "Use `and`, `or`, `not` when the operands are booleans."

15. Unsupervised process with the whole user copied. Line 49, `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`, starts a process no supervisor tracks, and the closure copies the entire `user`. Fix: `Task.Supervisor.start_child/2` under the application's supervisor, with a closure that captures only the email text. Rule: "Supervise every long-lived process" and "Send processes only the data they need."

16. Access on a struct. Line 53, `name = user[:name] || "there"`, raises `UndefinedFunctionError` because structs do not implement `Access`. Fix: the greeting uses `user.nickname`, a field the importer already sets. Rule: "Read required keys with `map.key` or a pattern."

17. Pipe into an anonymous function. Lines 54–55, `greeting |> (fn text -> ... end).()`, plus a temporary used once. Fix: one interpolated string. Rule: "Do not pipe into an anonymous function call."

18. Comments stand in for docs. Lines 2, 5, 7 and 48 describe the module, restate the code, or should be a `@doc`. The public function has no `@doc`. Fix: a `@moduledoc`, a `@doc` with a `## Options` section, and deletion of the comments that restate code. Line 11 stays, because it explains why the lowercasing happens. Rule: "Comments explain why; documentation goes in `@moduledoc` and `@doc`."

## Improved code

`lib/accounts/user_importer.ex`:

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external source, such as a CSV or JSON file.
  """

  alias Accounts.{Repo, User}

  @doc """
  Imports one user from string-keyed `params`.

  Returns `{:ok, user}` when the user is inserted. Returns `{:error, changeset}`
  when a field is missing or invalid, or when the database rejects the row, such
  as a duplicate email. The changeset's `errors` name the field.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, user} <- insert_user(params),
         :ok <- maybe_send_welcome(user, opts[:notify]) do
      {:ok, user}
    end
  end

  defp insert_user(params) do
    %User{}
    |> User.changeset(params)
    |> Repo.insert()
  end

  defp maybe_send_welcome(user, true), do: send_welcome(user)
  defp maybe_send_welcome(_user, false), do: :ok

  defp send_welcome(user) do
    email = welcome_email(user)
    deliver = fn -> Mailer.deliver(email) end
    {:ok, _pid} = Task.Supervisor.start_child(Accounts.TaskSupervisor, deliver)
    :ok
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

The importer relies on `Accounts.User.changeset/2`, which is in the schema module. That file was not in the input, so this is a sketch of what the function must do:

```elixir
defmodule Accounts.User do
  use Ecto.Schema

  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :age, :integer
    field :role, Ecto.Enum, values: [:admin, :member]
    field :nickname, :string

    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :age, :role, :nickname])
    |> validate_required([:email, :age, :role])
    |> update_change(:email, &String.downcase/1)
    |> update_change(:age, &min(&1, 120))
    |> validate_number(:age, greater_than_or_equal_to: 18)
    |> put_default_nickname()
    |> unique_constraint(:email)
  end

  defp put_default_nickname(changeset) do
    case get_field(changeset, :nickname) do
      nil -> put_change(changeset, :nickname, get_field(changeset, :email))
      _nickname -> changeset
    end
  end
end
```

## Assumptions and behavior changes

- The `Ecto.Enum` values (`:admin`, `:member`) are placeholders. Use the roles the project defines.
- `Accounts.TaskSupervisor` must be started in the application's supervision tree.
- `user.nickname` is assumed to be a field of the schema, as the original `%User{}` build implies.
- Callers that pass `:silent` or `:return_id` now get an error from `Keyword.validate!/2`.
- Callers that matched `{:error, :invalid}` or `{:error, :insert_failed}` now receive `{:error, changeset}`.
- An age above 120 is now stored as 120. The original code intended this but never applied it.
- The module is named `Accounts.*` without the application name. I could not check the name because the application is not in the input.
