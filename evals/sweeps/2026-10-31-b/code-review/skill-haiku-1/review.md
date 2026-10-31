# Review: `code-review-input.ex`

The module below applies every finding. It assumes a `User` schema and changeset that the input file does not show; the companion schema is at the end.

## Findings

Most severe first.

### 1. Atom created from user input

Rule: "Convert external strings to atoms with explicit clauses". Line 8, `role = String.to_atom(params["role"])`, lets anyone who sends a request add atoms to the VM's (virtual machine's) atom table, which is fixed in size and never freed, so enough requests crash the node. A missing role also raises before the `try` starts. Fix: declare `field :role, Ecto.Enum` on the schema, so the changeset maps `"admin"` to `:admin` and rejects anything else.

### 2. Welcome email never sends

Rule: "Read required keys with `map.key` or a pattern" (structs do not implement `Access`). Line 53, `user[:name]`, raises `UndefinedFunctionError` on a `%User{}` struct. The raise happens inside the spawned process, so nothing reports it. Fix: read a field the struct has. The module sets `nickname`, not `name`, so the fix uses `user.nickname`; confirm that is the field the greeting should use.

### 3. Age cap never applies

Rule: "Assign the result of `if`, `case`, and `Enum` calls". Lines 15-17 rebind `age` inside an `if`, and the outer `age` keeps its old value, so an age of 150 is stored as 150. Fix: cap the value on the changeset with `Ecto.Changeset.update_change/3`.

### 4. Input is not validated by a changeset

Rule: "Validate input with changesets" (ecto-phoenix reference). Line 22 builds `%User{}` by hand and line 25 inserts it, so the age and email checks in lines 15-41 are the only validation. Fix: `User.changeset/2` with `validate_number/3` and `unique_constraint(:email)`, then `Repo.insert/1` on the changeset. A duplicate then returns `{:error, changeset}`.

### 5. Duplicate check races the insert

Rule: "Declare database constraints in the changeset (`unique_constraint/3`...)". Lines 24-25 run `Repo.get_by/2` and then `Repo.insert/1`. Two imports of the same email can both pass the check. Fix: drop the lookup and rely on the unique index plus `unique_constraint/3`.

### 6. Function returns two shapes

Rule: "Give each function one return shape". Line 31, `if opts[:return_id], do: user.id, else: {:ok, user}`, returns a bare integer in one mode and a tuple in the other. Fix: `import_user/2` always returns `{:ok, user}`, and `import_user_id/2` wraps it and returns `{:ok, id}`.

### 7. Catch-all error clause

Rule: "Match every expected shape and let unexpected ones crash". Line 33, `_ -> {:error, :insert_failed}`, turns any future return value into the same error. Fix: match `{:error, changeset}` and return it.

### 8. Overlapping booleans and unchecked options

Rule: "Use one atom-valued field or option instead of overlapping booleans" and "check them with `Keyword.validate!/2`". Line 27, `opts[:notify] && !opts[:silent]`, uses `silent` only to undo `notify`, and a misspelled option is ignored without a message. Fix: keep `notify` and remove `silent`, validated with `Keyword.validate!(opts, notify: false)`. This is a breaking change: callers that pass `silent:` now get an `ArgumentError` and should drop the key.

### 9. Unsupervised process that copies the whole struct

Rule: "Supervise every long-lived process" and "Send processes only the data they need" (processes reference). Line 49, `spawn(fn -> Mailer.deliver(welcome_email(user)) end)`, has no supervisor, so a crash is not recorded, and the closure copies `user` in full. Fix: build the email before the spawn and start it with `Task.Supervisor.start_child/2`. This needs `Accounts.TaskSupervisor` in the application's supervision tree.

### 10. Single-step pipe and pipe into a lambda

Rule: "Do not pipe a single step" and "Do not pipe into an anonymous function call". Line 12, `params["email"] |> String.downcase()`, is one step. Line 55, `greeting |> (fn text -> ... end).()`, pipes into a lambda that only appends a string. Fix: call `String.downcase/1` directly, and write the greeting as one interpolated string.

### 11. One function does four jobs at four levels of nesting

Rule: "Keep functions short and at one level of detail". `import_user/2` runs from line 6 to line 45, nests `if`, `case`, and `if` again, and uses `&&` on boolean checks (line 21), where the rule "Use `and`, `or`, `not` when the operands are booleans" applies. Fix: separate functions for building the attributes, inserting, and sending the welcome email.

### 12. Comments that restate the code, and no `@doc`

Rule: "Comments explain why; documentation goes in `@moduledoc` and `@doc`". Lines 2, 5, 7, and 48 restate what the next line does. The public `import_user/2`, which takes options, has no `@doc`. Fix: move the module description to `@moduledoc`, document the function and its options in `@doc`, and keep the comment on line 11, which explains why the email is lowercased.

## Improved module

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external source, such as a CSV (comma-separated values)
  or JSON (JavaScript Object Notation) file.
  """

  alias Accounts.{Repo, User}

  @max_age 120

  @doc """
  Imports a single user from `params`.

  Returns `{:ok, user}` or `{:error, changeset}`. The changeset carries the
  validation or database error, such as a duplicate email.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, user} <- insert_user(user_attrs(params)) do
      if opts[:notify], do: send_welcome(user)

      {:ok, user}
    end
  end

  @doc """
  Imports a single user, like `import_user/2`, and returns `{:ok, id}`.
  """
  def import_user_id(params, opts \\ []) do
    with {:ok, user} <- import_user(params, opts), do: {:ok, user.id}
  end

  defp user_attrs(params) do
    email = normalize_email(params["email"])

    %{
      "email" => email,
      "age" => params["age"],
      "role" => params["role"],
      "nickname" => params["nickname"] || email
    }
  end

  # The provider lowercases addresses before its uniqueness check, so match it here
  defp normalize_email(email) when is_binary(email), do: String.downcase(email)
  defp normalize_email(email), do: email

  defp insert_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> cap_age()
    |> Repo.insert()
  end

  defp cap_age(changeset) do
    Ecto.Changeset.update_change(changeset, :age, &min(&1, @max_age))
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

## Companion schema (assumed)

The improved module expects a changeset like this. The role values are placeholders; use the project's own roles, and add a unique index on `email` in the migration.

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
    |> validate_required([:email, :age, :role])
    |> validate_format(:email, ~r/@/)
    |> validate_number(:age, greater_than_or_equal_to: 18)
    |> unique_constraint(:email)
  end
end
```

## Behavior changes

- `import_user/2` returns `{:error, changeset}` where it returned `{:error, :invalid}` or `{:error, :insert_failed}`. Callers that match those atoms need updating.
- `silent:` is no longer accepted. `return_id:` moved to `import_user_id/2`.
- Ages above 120 are now capped, as the original code intended.
- Welcome emails are sent. The original never sent them (finding 2).

## Verification

The improved code was not compiled or run through `mix format`; the shell was unavailable for that check. Compile it and run `mix format --check-formatted` on it before use.
