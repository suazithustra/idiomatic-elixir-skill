# Review: `Accounts.UserImporter`

Rules come from the idiomatic-elixir skill, plus its `ecto-phoenix.md` and `processes.md` references.

## Findings

1. **`String.to_atom/1` on external input** (`role = String.to_atom(params["role"])`)
   - Rule: convert external strings to atoms with explicit clauses.
   - Atoms are never garbage-collected, so anyone controlling `params["role"]` can exhaust the atom table. A missing `"role"` also crashes outside the `try`.
   - Fix: make `role` an `Ecto.Enum` field and `cast/3` it, so an unknown role gives a changeset error.

2. **`try ... rescue _ -> {:error, :invalid}` around the whole function**
   - Rule: return tuples for expected failures; never `rescue _` around a whole function.
   - It hides real bugs, such as a failing `Repo` call, behind `:invalid`. It exists only to catch `String.to_integer/1`, `String.downcase/1` on `nil` and `String.to_atom/1`.
   - Fix: let `cast/3` do the conversions, which return errors instead of raising.

3. **`Repo.insert(%User{...})` with hand-built validation**
   - Rule (ecto-phoenix): validate input with changesets, not by hand.
   - The struct is inserted unvalidated, and the age and email checks are hand-written.
   - Fix: `User.changeset/2` with `cast`, `validate_required`, `validate_number` and `update_change`.

4. **Lookup before insert** (`Repo.get_by(User, email: email) == nil`)
   - Rule: use `unique_constraint/3` instead of a check-then-insert.
   - It is racy: two concurrent imports both pass the check and one insert raises.
   - Fix: `unique_constraint(:email)`, so the loser gets `{:error, changeset}`.

5. **Catch-all `_ -> {:error, :insert_failed}`**
   - Rule: match every expected shape.
   - It throws away the changeset errors.
   - Fix: match `{:error, %Ecto.Changeset{}}` and return it. Callers can now tell which field failed.

6. **`if age > 120 do age = 120 end`**
   - Rule: rebinding inside `if` does not escape the block.
   - The clamp never happens, and the compiler warns that the inner `age` is unused.
   - Fix: `update_change(:age, &min(&1, @max_age))`.

7. **`&&` and `!` on booleans**
   - Rule: use `and`, `or` and `not` when the operands are booleans.
   - Affected lines: `is_binary(email) && age >= 18` and `opts[:notify] && !opts[:silent]`.
   - `is_binary(email)` is also dead code: `String.downcase/1` has already raised if `email` was not a binary.
   - Fix: the check is gone, since `cast/3` guarantees a string.

8. **Overlapping booleans `notify` and `silent`**
   - Rule: use one atom-valued option instead of overlapping booleans.
   - `notify: true, silent: true` is meaningless. Fix: a single `:notify` option.

9. **`:return_id` changes the return shape**
   - Rule: give each function one return shape.
   - Without `:return_id` the function returns `{:ok, user}`; with it, a bare id. That also clashes with `{:error, _}` handling.
   - Fix: drop the option. Callers use `{:ok, user}` and read `user.id`.

10. **Options not validated or documented**
    - Rule: check options with `Keyword.validate!/2` and document them under `## Options`.

11. **Bare `spawn/1` for email** (`spawn(fn -> Mailer.deliver(...) end)`)
    - Rule (processes): supervise every long-lived process, and send processes only the data they need.
    - An unsupervised process is invisible and unmonitored. The closure also copies the whole `user` struct.
    - Fix: `Task.Supervisor.start_child(Accounts.TaskSupervisor, ...)`, building the email first so the closure captures only the email. The supervisor must be added to the application's children.

12. **`user[:name]` on a struct**
    - Rule: structs do not implement `Access`, so this raises `UndefinedFunctionError`.
    - Fix: read `user.name` with a pattern. This assumes `User` has a `:name` field; the importer never sets one, so check that.

13. **Piping into an anonymous function** (`greeting |> (fn text -> ... end).()`) and string concatenation
    - Rule: do not pipe into an anonymous function.
    - Fix: a single interpolated string.

14. **Magic numbers 18 and 120**
    - Rule: name them with module attributes (`@min_age`, `@max_age`).

15. **Comments that restate code, and missing docs**
    - Rule: comments explain why; docs go in `@moduledoc` and `@doc`.
    - Examples: `# Get the role from params`, `# send the email`.
    - `# Import a single user...` and `# This module imports...` should be `@moduledoc` and `@doc`.
    - Kept: the comment about the provider's lowercasing, which explains a reason.
    - Also add `@spec` and put `alias` after `@moduledoc`.

16. **Required keys read with `params["key"]`**
    - Rule: read required keys strictly or validate them.
    - `params["email"]` and `params["age"]` return `nil` for missing keys and fail later with a confusing error.
    - Fix: `validate_required` reports a missing field by name.

17. **Public function mixes levels of detail**
    - Rule: keep functions short and at one level.
    - `if`, `case` and `if` were nested four deep.

## Behaviour changes

- Errors are now `{:error, %Ecto.Changeset{}}` instead of `:invalid` or `:insert_failed`. Update callers.
- `return_id` and `silent` are gone.
- `User` needs `role` as an `Ecto.Enum`, a unique index on `email`, and the changeset below.

## Improved code

```elixir
defmodule Accounts.User do
  # Excerpt: the changeset the importer relies on.
  import Ecto.Changeset

  @min_age 18
  @max_age 120

  def changeset(user, params) do
    user
    |> cast(params, [:email, :age, :role, :nickname])
    |> validate_required([:email, :age, :role])
    # The provider lowercases addresses before its uniqueness check, so match it here
    |> update_change(:email, &String.downcase/1)
    |> update_change(:age, &min(&1, @max_age))
    |> validate_number(:age, greater_than_or_equal_to: @min_age)
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

defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV/JSON source.
  """

  alias Accounts.{Repo, User}

  @doc """
  Imports a single user from string-keyed `params`.

  Returns `{:ok, user}`, or `{:error, changeset}` when the params are invalid
  or the email is already taken.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    changeset = User.changeset(%User{}, params)

    case Repo.insert(changeset) do
      {:ok, user} ->
        if opts[:notify], do: send_welcome(user)
        {:ok, user}

      {:error, %Ecto.Changeset{}} = error ->
        error
    end
  end

  defp send_welcome(user) do
    email = welcome_email(user)

    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(%User{name: nil}), do: "Hi there, welcome! Enjoy your account."
  defp welcome_email(%User{name: name}), do: "Hi #{name}, welcome! Enjoy your account."
end
```
