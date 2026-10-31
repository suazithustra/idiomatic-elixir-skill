# Review: `Accounts.UserImporter`

Read first: `SKILL.md`, `references/processes.md` (code uses `spawn`), `references/ecto-phoenix.md` (code uses `Repo`).

## Findings

1. **Bug: `age = 120` inside `if` has no effect** (rule: assign the result of `if`; rebinding inside a block does not escape it).
   `if age > 120 do age = 120 end` leaves `age` unchanged, so ages above 120 are stored as given. Fix: `min(age, @max_age)`.

2. **`String.to_atom(params["role"])` on external input** (rule: convert external strings to atoms with explicit clauses).
   Anyone who controls the CSV/JSON can exhaust the atom table and crash the node. A missing role also raises on `nil`. Fix: `parse_role/1` with one clause per accepted role and `{:error, {:unknown_role, other}}` as the catch-all.
   The roles listed (`admin`, `member`) are my assumption. Replace them with the real set.

3. **`try ... rescue _ -> {:error, :invalid}` around the whole function** (rule: return tuples for expected failures; never `rescue _`).
   It turns every bug (a typo, a `KeyError`, a database outage) into `:invalid`. `String.to_integer/1` and `String.downcase/1` only raised on bad input, which `Integer.parse/1` and a function-head pattern handle without raising. The `rescue` is removed.

4. **Lookup before insert: `Repo.get_by(User, email: email) == nil`** (rule: declare constraints in the changeset, `unique_constraint/3`).
   Two imports of the same email can both pass the check and both insert (a race). Only a database unique index closes that gap. Fix: `unique_constraint(:email)` in the changeset, so a duplicate returns `{:error, changeset}`.

5. **Raw `%User{}` passed to `Repo.insert/1`** (rule: validate input with changesets).
   Nothing is validated and a constraint violation raises. The hand checks (`age >= 18`, `is_binary(email)`) move into `User.import_changeset/2` below. The `is_binary(email)` check ran after `String.downcase(email)`, which had already raised for a non-binary, so it could never fail.

6. **`_ -> {:error, :insert_failed}` and reuse of `:invalid`** (rule: match every expected shape; different failures need different reasons).
   The insert error is dropped, and a duplicate email, an underage user and a bad age all return `{:error, :invalid}`. Fix: return `{:error, changeset}` from the insert and distinct reasons (`:invalid_params`, `{:invalid_age, value}`, `{:unknown_role, value}`) from parsing.

7. **Required keys read with `params["email"]`, no clause for malformed input** (rule: match the required keys of string-keyed input in the head, with a catch-all clause).
   Fix: `import_user(%{"email" => email, "age" => age, "role" => role} = params, opts)` plus `import_user(_params, _opts)` returning `{:error, :invalid_params}`. `"nickname"` stays optional, so it is read with `params["nickname"] || email`.

8. **Overlapping booleans `:notify` and `:silent`** (rule: one atom-valued field instead of overlapping booleans).
   `notify: true, silent: true` is meaningless. Reduced to `:notify`, default `false`, checked with `Keyword.validate!/2` and documented under `## Options`.

9. **`:return_id` changes the return shape** (rule: one return shape per function).
   The function returns either `user.id` or `{:ok, user}`. Removed. Callers who want the id read `user.id` from `{:ok, user}`. This is a change to the public API, so check callers.

10. **`&&` and `!` on booleans** (rule: `and`, `or`, `not` when operands are booleans). `is_binary(email) && age >= 18` and `opts[:notify] && !opts[:silent]`. The first moves into the changeset; the second goes away with finding 8.

11. **`spawn/1` outside a supervisor** (`processes.md`: supervise every long-lived process; fire-and-forget work uses `Task.Supervisor.start_child/2`).
    A crash in `Mailer.deliver/1` is invisible and the work is lost on shutdown. Fix: `Task.Supervisor.start_child(Accounts.TaskSupervisor, ...)`. This needs `{Task.Supervisor, name: Accounts.TaskSupervisor}` in the application's supervision tree. The closure also captured the whole `user`; it now captures only the nickname (`processes.md`: send processes only the data they need).

12. **`user[:name]` on a struct** (rule: structs do not implement `Access`).
    `%User{}` raises `UndefinedFunctionError` on `user[:name]`, so the welcome email would crash in the spawned process, silently. The importer never sets a `:name`; the new code greets the `nickname`, which it always sets. If `User` has a real `:name` field, use that.

13. **Piping into an anonymous function** (`greeting |> (fn text -> ... end).()`). Replaced with one interpolated string.

14. **Single-step pipe** `params["email"] |> String.downcase()` becomes `String.downcase(email)`.

15. **Deep nesting in a public function** (`try` > `if` > `if` > `case` > `if`). Split into `parse_age/1`, `parse_role/1`, `insert_user/1` and `maybe_send_welcome/2`, chained with `with`.

16. **Comments that restate code** (`# Get the role from params`, `# send the email`, `# Import a single user...`) removed. The comment explaining that the provider lowercases addresses is a real reason and is kept. Documentation moved to `@moduledoc` and `@doc`. Magic numbers `120` and `18` are named (`@max_age`) or moved to the changeset.

17. **Mailer reference.** `Mailer.deliver/1` is not aliased and no recipient is passed, so the email as written cannot reach anyone. I kept the call shape and left a note rather than guess at the Mailer API. Check this.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from external CSV/JSON rows.
  """

  alias Accounts.{Repo, User}

  @max_age 120

  @doc """
  Imports a single user from string-keyed `params`.

  Requires `"email"`, `"age"` and `"role"`; `"nickname"` is optional and
  defaults to the email. Ages above #{@max_age} are stored as #{@max_age}.

  Returns `{:ok, user}`, `{:error, :invalid_params}`, `{:error, {:invalid_age, value}}`,
  `{:error, {:unknown_role, value}}` or `{:error, changeset}`.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ [])

  def import_user(%{"email" => email, "age" => age, "role" => role} = params, opts)
      when is_binary(email) do
    opts = Keyword.validate!(opts, notify: false)

    # The provider lowercases addresses before its uniqueness check, so match it here
    email = String.downcase(email)

    with {:ok, age} <- parse_age(age),
         {:ok, role} <- parse_role(role),
         attrs = %{email: email, age: age, role: role, nickname: params["nickname"] || email},
         {:ok, user} <- insert_user(attrs) do
      maybe_send_welcome(user, Keyword.fetch!(opts, :notify))
      {:ok, user}
    end
  end

  def import_user(_params, _opts), do: {:error, :invalid_params}

  defp parse_age(age) when is_integer(age), do: {:ok, min(age, @max_age)}

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {age, ""} ->
        {:ok, min(age, @max_age)}

      _ ->
        {:error, {:invalid_age, age}}
    end
  end

  defp parse_age(age), do: {:error, {:invalid_age, age}}

  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("member"), do: {:ok, :member}
  defp parse_role(other), do: {:error, {:unknown_role, other}}

  defp insert_user(attrs) do
    %User{}
    |> User.import_changeset(attrs)
    |> Repo.insert()
  end

  defp maybe_send_welcome(user, true), do: send_welcome(user)
  defp maybe_send_welcome(_user, false), do: :ok

  defp send_welcome(user) do
    nickname = user.nickname

    {:ok, _pid} =
      Task.Supervisor.start_child(Accounts.TaskSupervisor, fn ->
        Mailer.deliver(welcome_email(nickname))
      end)

    :ok
  end

  defp welcome_email(nickname), do: "Hi #{nickname}, welcome! Enjoy your account."
end
```

Companion change in `Accounts.User` (the importer now depends on it):

```elixir
def import_changeset(user, attrs) do
  user
  |> cast(attrs, [:email, :age, :role, :nickname])
  |> validate_required([:email, :age, :role, :nickname])
  |> validate_number(:age, greater_than_or_equal_to: 18)
  |> unique_constraint(:email)
end
```

`unique_constraint(:email)` needs a unique index on `email` (on `lower(email)` if the provider's check is case-insensitive). The `with` line `attrs = ...` is a plain match inside `with`; if you prefer, move it into `insert_user/1`.
