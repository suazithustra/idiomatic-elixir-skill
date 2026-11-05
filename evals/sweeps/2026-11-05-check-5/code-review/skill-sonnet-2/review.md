# Review of `Accounts.UserImporter`

The module builds a `%User{}` by hand, validates it with ad hoc checks, and hides every failure behind one `rescue`. Several of the checks do not do what they appear to. The fix is to move validation into a changeset (Ecto's validation struct) and let the database enforce uniqueness.

## Findings

1. **Atom created from input** (`String.to_atom/1` on `params["role"]`, line 8). Atoms are never garbage-collected, so anyone who controls the input can exhaust the atom table and crash the node. Fix: cast `role` through the changeset with an `Ecto.Enum` field, so only listed values are accepted.

2. **`try/rescue _ ->` around the whole function** (lines 10-44). It turns every bug (missing key, `MatchError`, a database error) into `{:error, :invalid}`. Fix: remove it. Expected failures come back as `{:error, changeset}`; bugs crash.

3. **Rebinding inside `if` does not escape** (`if age > 120 do age = 120 end`, lines 15-17). `age` stays unchanged, so the cap never applies, and the compiler warns. Fix: validate the range in the changeset with `validate_number(:age, greater_than_or_equal_to: 18, less_than_or_equal_to: 120)`. This rejects ages over 120 instead of capping them, because the cap never worked; if capping is wanted, write `age = min(age, 120)`.

4. **Struct built from params and passed to `Repo.insert/1`** (line 22). Nothing is validated and a constraint violation raises. Fix: `User.changeset/2` with `cast/3`, `validate_required/2`, `validate_number/3` and `Ecto.Enum`.

5. **Lookup before insert** (`Repo.get_by(...) == nil`, line 24). This races: two imports of the same email can both pass the check, and the second insert raises. Fix: `unique_constraint(:email)` in the changeset, so the duplicate returns `{:error, changeset}`. The unique index must exist on the lowercased email.

6. **`String.to_integer/1` and `String.downcase/1` on raw params** (lines 12-13). A missing or malformed value raises, and the `rescue` hides it. `is_binary(email)` is checked after `String.downcase(email)` has already run, so the check can never fail. Fix: `cast/3` converts `"30"` to `30` and returns an error for `"abc"`; lowercase with `update_change(:email, &String.downcase/1)`.

7. **Return shape depends on an option** (`opts[:return_id]`, line 31). It returns either an id or `{:ok, user}`. Fix: remove the option; always return `{:ok, user}`. Callers read `user.id`.

8. **Overlapping booleans** (`opts[:notify] && !opts[:silent]`, line 27). `silent` only cancels `notify`. Fix: a single `notify` option, validated with `Keyword.validate!/2` and documented under `## Options`.

9. **`&&` and `!` on booleans** (lines 21 and 27). Gone with findings 6 and 8.

10. **Catch-all `_ ->` clause** (line 33) discards the changeset errors and names a cause (`:insert_failed`) it cannot know. Fix: match `{:error, changeset}` by passing it through `with`.

11. **Wrong error reasons** (`{:error, :invalid}` for an underage user, a duplicate email and any crash, lines 37, 40, 43). The caller cannot tell them apart. Fix: the changeset's errors carry the field and reason.

12. **Nested `if`/`case`/`if`/`else`** (lines 21-41) four levels deep. Gone with the changeset; the function is now `with` plus a private `insert_user/1`.

13. **Bare `spawn/1`** for the email (line 49). The process is unsupervised, and a crash goes unreported. It also copies the whole `user`. Fix: `Task.Supervisor.start_child(Accounts.TaskSupervisor, ...)`. The supervisor must be in the application's child list. The email is sent only after `Repo.insert/1` has returned `{:ok, user}`, so nothing is sent for a failed insert.

14. **`user[:name]` on a struct** (line 53). Structs do not implement `Access`, so this raises `UndefinedFunctionError` every time; inside the spawned process, the failure is silent. The `|| "there"` fallback therefore never ran. Fix: read `user.nickname`, which the changeset defaults to the email.

15. **Pipe into an anonymous function** (`greeting |> (fn text -> ... end).()`, line 55) and a pointless `greeting` temporary. Fix: one interpolated string.

16. **Comments that restate code** (`# Get the role from params`, `# send the email`, the header comments) and docs written as comments. Fix: delete them and use `@moduledoc` and `@doc` with `## Options`. The comment about the provider lowercasing addresses explains a reason, so the changeset keeps it.

17. **`String.downcase` piped with one step** (`params["email"] |> String.downcase()`, line 12). Gone with finding 6.

## Assumptions

- `Accounts.User.changeset/2` is new or updated as sketched below. `Mailer` is left unaliased as in the original; it should be namespaced under `Accounts` or the app. The `Ecto.Enum` role values are placeholders.
- Behavior changes: duplicates and invalid input return `{:error, changeset}` instead of `{:error, :invalid}`; ages over 120 are rejected instead of (intended) capped; `:return_id` and `:silent` are removed.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV/JSON source.
  """

  alias Accounts.Repo
  alias Accounts.User

  @doc """
  Imports a single user from string-keyed `params`.

  Returns `{:ok, user}`, or `{:error, changeset}` when the params are invalid
  or the email is already taken.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, user} <- insert_user(params) do
      if opts[:notify], do: send_welcome(user)

      {:ok, user}
    end
  end

  defp insert_user(params) do
    %User{}
    |> User.changeset(params)
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

Supporting changeset in `Accounts.User`:

```elixir
schema "users" do
  field :email, :string
  field :age, :integer
  field :role, Ecto.Enum, values: [:admin, :member]
  field :nickname, :string
end

def changeset(user, params) do
  user
  |> cast(params, [:email, :age, :role, :nickname])
  |> validate_required([:email, :age, :role])
  # The provider lowercases addresses before its uniqueness check, so match it here
  |> update_change(:email, &String.downcase/1)
  |> validate_number(:age, greater_than_or_equal_to: 18, less_than_or_equal_to: 120)
  |> put_default_nickname()
  |> unique_constraint(:email)
end

defp put_default_nickname(changeset) do
  case fetch_field(changeset, :nickname) do
    {_source, nickname} when is_binary(nickname) ->
      changeset

    {_source, nil} ->
      put_change(changeset, :nickname, get_field(changeset, :email))
  end
end
```
