# Review of `Accounts.UserImporter`

Elixir (and `mix format`) was not run on the improved code: the `Accounts.User`, `Repo` and `Mailer` modules are not available here.

## Findings

1. **`String.to_atom/1` on input** (rule: convert external strings to atoms with explicit clauses). `role = String.to_atom(params["role"])` lets anyone who controls the input exhaust the atom table. It also raises on a missing role (`nil`). Fix: declare `role` as an `Ecto.Enum` on the schema and let `cast/3` convert it. An unknown role becomes a changeset error.

2. **`try/rescue` with `_ ->` around the whole function** (rule: return tuples, raise only for bugs). `rescue _ -> {:error, :invalid}` turns every bug, including a `Repo` failure, into `:invalid`. It exists only because `String.downcase(nil)`, `String.to_integer/1` and `String.to_atom/1` raise on bad input. Fix: validate with a changeset, which returns `{:error, changeset}` and does not raise.

3. **Hand-built validation instead of a changeset** (`ecto-phoenix.md`). `%User{...}` goes straight to `Repo.insert/1`, with a manual age check and a `String.to_integer/1` parse. Fix: `User.changeset/2` with `cast/3`, `validate_required/2`, `validate_number/3`.

4. **Lookup before insert** (rule: `unique_constraint/3`). `Repo.get_by(User, email: email) == nil` is a check-then-insert race: two imports of the same email can both pass the check, and the second insert raises. Fix: `unique_constraint(:email)` in the changeset, so the violation comes back as `{:error, changeset}`.

5. **Rebinding inside `if`** (rule: assign the result of `if`). `if age > 120 do age = 120 end` leaves `age` unchanged and produces a compiler warning. The intent was to cap the age. The improved version rejects ages above 120 with `validate_number/3`. **This is a behavior change**: the original meant to clamp, the new code returns an error. If you want clamping, add `update_change(:age, &min(&1, 120))` before the validation.

6. **`_ ->` catch-all on `Repo.insert/1`** (rule: match every expected shape). `_ -> {:error, :insert_failed}` throws away the changeset errors. Fix: pass `{:error, %Ecto.Changeset{}}` through. The caller can then see which field failed.

7. **Three different error reasons for unrelated failures.** `{:error, :invalid}` is returned for a duplicate email, an age below 18 and any exception. The caller cannot tell them apart. Fix: the changeset errors carry the field and the reason.

8. **Option changes the return shape** (rule: one return shape). `if opts[:return_id], do: user.id, else: {:ok, user}` returns an id or a tuple, and the id form has no error branch for the caller to match. Fix: always return `{:ok, user}`. Callers that want the id read `user.id`.

9. **Overlapping booleans** (rule: one option instead of overlapping booleans). `notify` and `silent` conflict when both are true. Fix: keep only `:notify`, default `false`, checked with `Keyword.validate!/2`.

10. **`&&` and `!` on booleans** (rule: `and`, `or`, `not`). `is_binary(email) && age >= 18` has boolean operands. The check goes away with the changeset, and `opts[:notify] && !opts[:silent]` goes with the `:silent` option.

11. **Bare `spawn/1` for the email** (`processes.md`: supervise every long-lived process). The unsupervised process is not linked to anything, and its failures are invisible. The closure also copies the whole `user` struct. Fix: `Task.Supervisor.start_child/2` under a named supervisor, `Accounts.TaskSupervisor`, which must be started in the application's supervision tree.

12. **`user[:name]` on a struct** (rule: structs do not implement `Access`). It raises `UndefinedFunctionError` the first time a welcome email is sent. The importer also never sets `name`. Fix: use `user.nickname`, which the importer does set. If `User` has a `name` field, use that instead.

13. **Piping into an anonymous function** (rule: do not pipe into `(fn ... end).()`). `greeting |> (fn text -> ... end).()` is a string concatenation written the long way. Fix: one interpolated string.

14. **Variable pipeline with one step** (rule: do not pipe a single step). `params["email"] |> String.downcase()` becomes `update_change(:email, &String.downcase/1)` in the changeset.

15. **Comments that restate code, and docs written as comments.** `# Get the role from params`, `# send the email`, and the `#` comments above the module and `import_user/2` are replaced by `@moduledoc` and `@doc` with options and an example. The comment about the provider lowercasing addresses explains a reason, so it stays, next to the `update_change/3` call.

16. **Unaliased `Mailer`.** `Mailer.deliver/1` is called without an alias or namespace. It is probably meant to be `Accounts.Mailer`. I kept the name as written and aliased it from `Accounts` in the improved code, so check that the module exists.

17. **Optional-key reads.** `params["role"]`, `params["email"]` and `params["age"]` were read with `[]` and then used as if required. `cast/3` and `validate_required/2` now state this.

## Assumed `Accounts.User` changeset

The improved importer depends on this. It is not in the input file, so adjust it to the real schema.

```elixir
@roles [:member, :admin]

schema "users" do
  field :email, :string
  field :age, :integer
  field :role, Ecto.Enum, values: @roles
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
  put_change(changeset, :nickname, get_field(changeset, :nickname) || get_field(changeset, :email))
end
```

`cast/3` converts the string age `"42"` to an integer and adds a changeset error for `"abc"`, so `String.to_integer/1` is no longer needed.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.Mailer
  alias Accounts.Repo
  alias Accounts.User

  @doc """
  Imports a single user from string-keyed `params`.

  Returns `{:ok, user}`, or `{:error, changeset}` when the params are invalid
  or the email is already taken.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.

  ## Examples

      Accounts.UserImporter.import_user(
        %{"email" => "Ada@Example.com", "age" => "36", "role" => "admin"},
        notify: true
      )
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    changeset = User.changeset(%User{}, params)

    with {:ok, user} <- Repo.insert(changeset) do
      if Keyword.fetch!(opts, :notify), do: send_welcome(user)

      {:ok, user}
    end
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
