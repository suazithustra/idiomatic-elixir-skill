# Review: `Accounts.UserImporter`

I followed the idiomatic-elixir skill and read its `processes.md` (because of `spawn`) and `ecto-phoenix.md` (because of `Repo`). The improved code has not been compiled or run, because the `User`, `Repo` and `Mailer` modules are not available here.

## Findings

1. **A rebinding inside `if` has no effect (rule: assign the result of `if`).** `if age > 120 do age = 120 end` leaves `age` unchanged, so the cap on age never applies. Fix: `age = min(age, 120)`.

2. **`String.to_atom/1` on external input (rule: convert external strings to atoms with explicit clauses).** `role = String.to_atom(params["role"])` lets any caller exhaust the atom table, and a missing role raises on `nil`. Fix: make `role` an `Ecto.Enum` field and let `cast/3` accept only the listed values.

3. **`try ... rescue _ ->` around the whole function (rule: return tuples for expected failures; raise only for bugs).** It turns every bug into `{:error, :invalid}`, including a failure inside `Repo.insert` or a typo. Fix: remove it and use non-raising parsing (`Integer.parse/1`), with explicit error reasons.

4. **`String.to_integer(params["age"])` raises on bad input.** Fix: `Integer.parse/1`, matching `{age, ""}` and `:error` explicitly.

5. **The `is_binary(email)` check comes after `String.downcase(email)`.** A non-string email raises before the check runs, so the check does nothing. Fix: validate the field first (`string_field/2`), then downcase.

6. **`&&` and `!` on booleans (rule: use `and`, `or`, `not` for booleans).** `is_binary(email) && age >= 18` should use `and`. The `opts[:notify] && !opts[:silent]` line goes away with finding 8.

7. **A catch-all `_ ->` on `Repo.insert/1` hides the reason.** The changeset error is lost behind `{:error, :insert_failed}`. Fix: match `{:error, changeset}` and return it.

8. **Overlapping booleans `notify:` and `silent:`.** `notify: true, silent: true` is contradictory. Fix: a single `:notify` option, checked with `Keyword.validate!/2`.

9. **`:return_id` changes the return shape.** The function returns either `user.id` or `{:ok, user}`. Fix: always return `{:ok, user}`. Callers that want the id use `user.id`.

10. **A struct built from params goes straight to `Repo.insert/1`.** Nothing is validated and a unique-email violation raises. Fix: use `User.changeset/2` with `cast/3`, `validate_required/2`, `validate_number/3` and `unique_constraint/2` (sketch below).

11. **`user[:name]` on a struct raises `UndefinedFunctionError`.** Structs do not implement `Access`. Fix: `user.name`. This assumes `User` has a `:name` field. The old code never set it, and the field is probably nil here, which the `|| "there"` default covers.

12. **Unsupervised `spawn/1` for the email.** A crash is silent, and the process is not tracked. Fix: `Task.Supervisor.start_child/2` under a supervisor that you must add to the application tree (`{Task.Supervisor, name: Accounts.TaskSupervisor}`).

13. **Piping into an anonymous function, `greeting |> (fn ... end).()`.** Fix: build the string with one interpolation.

14. **Comments that restate the code, and no docs.** `# Get the role from params`, `# send the email` and similar add nothing. The module and public function have no `@moduledoc` or `@doc`. I kept the comment about the provider lowercasing, since it explains a reason. I also documented `## Options`.

15. **Nested `if`/`case` inside a `try`.** `import_user/2` mixed parsing, insert, notification and return-shape logic. Fix: a short `with` over small private functions.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV/JSON source.
  """

  alias Accounts.{Repo, User}

  @max_age 120

  @doc """
  Imports a single user from string-keyed `params`.

  Returns `{:ok, user}`, `{:error, {:missing_field, key}}`,
  `{:error, {:invalid_field, key}}`, or `{:error, changeset}` when validation
  or a database constraint fails.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
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
         {:ok, age} <- parse_age(params) do
      # The provider lowercases addresses before its uniqueness check, so match it here
      email = String.downcase(email)

      {:ok,
       %{
         email: email,
         age: min(age, @max_age),
         role: params["role"],
         nickname: params["nickname"] || email
       }}
    end
  end

  defp parse_age(params) do
    with {:ok, raw_age} <- string_field(params, "age") do
      case Integer.parse(raw_age) do
        {age, ""} -> {:ok, age}
        {_age, _rest} -> {:error, {:invalid_field, "age"}}
        :error -> {:error, {:invalid_field, "age"}}
      end
    end
  end

  defp string_field(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp insert_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp send_welcome(user) do
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn ->
      Mailer.deliver(welcome_email(user))
    end)
  end

  defp welcome_email(user) do
    name = user.name || "there"
    "Hi #{name}, welcome! Enjoy your account."
  end
end
```

## Supporting changes assumed

`User.changeset/2`, with `role` declared as an `Ecto.Enum` in the schema (`field :role, Ecto.Enum, values: [...]`):

```elixir
def changeset(user, attrs) do
  user
  |> cast(attrs, [:email, :age, :role, :nickname])
  |> validate_required([:email, :age, :role])
  |> validate_number(:age, greater_than_or_equal_to: 18)
  |> unique_constraint(:email)
end
```

Add `{Task.Supervisor, name: Accounts.TaskSupervisor}` to the application's children list.

Behavior changes to tell callers about: `:silent` and `:return_id` are gone, and errors are now specific tuples or changesets instead of `:invalid` and `:insert_failed`.
