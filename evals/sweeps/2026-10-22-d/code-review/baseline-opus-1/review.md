# Review: `Accounts.UserImporter`

## Findings

### Bugs / correctness

1. **`String.to_atom/1` on external input (line 8) — security bug.** Atoms are never garbage-collected; an import file with many distinct `role` values can exhaust the atom table and crash the VM. Map the input against an explicit allowlist of known roles instead (or at the very least use `String.to_existing_atom/1`).

2. **Role conversion sits outside the `try` (line 8).** A missing `role` (`String.to_atom(nil)`) raises out of `import_user/2`, while every other bad field returns `{:error, :invalid}`. The function's error contract is inconsistent depending on which field is bad.

3. **The age clamp does nothing (lines 15–17).** `age = 120` inside `if` binds a new variable scoped to that block; the outer `age` is unchanged (the compiler warns about an unused variable). Ages over 120 are stored as given. Use `min(age, 120)`.

4. **`user[:name]` raises (line 53).** Structs don't implement `Access`, so `user[:name]` on a `%User{}` raises `UndefinedFunctionError`. And `User` has no `:name` field anyway — the importer only sets `:nickname`. Because this runs inside `spawn`, the crash is silent and **no welcome email is ever sent**.

5. **Check-then-insert race (lines 24–25).** `Repo.get_by` followed by `Repo.insert` is not atomic; two concurrent imports of the same email can both pass the check. Rely on a database unique index plus `Ecto.Changeset.unique_constraint/2`, which also removes the extra query.

6. **Blanket `rescue _` (lines 42–44).** It turns every exception — including DB connection errors, bugs in this module and bugs in `send_welcome` — into `{:error, :invalid}`. Real failures get hidden and reported as bad input. Validate input explicitly (`Integer.parse/1`, pattern matching) and let unexpected errors crash.

7. **`is_binary(email)` is dead code (line 21).** `String.downcase/1` has already raised if `email` isn't a binary, so this check is always true when reached.

8. **Errors don't say what went wrong.** A duplicate email returns `{:error, :invalid}` (the same as a malformed row), and insert failures drop the changeset (`_ -> {:error, :insert_failed}`). The caller can't tell an underage user from a duplicate from a DB validation error. Return distinct reasons or the changeset.

### Design / API

9. **`:return_id` changes the return type.** With the option set, success returns a bare integer and failure returns a tuple, so callers can't pattern-match on one shape. Always return `{:ok, user}`; callers who want the id can match `{:ok, %User{id: id}}`. *(This is a breaking change for any caller that uses `:return_id`.)*

10. **`:notify` and `:silent` overlap.** Two flags control one behaviour, and `notify: true, silent: true` is a contradiction the code settles quietly. A single `:notify` flag is enough. *(Breaking for callers that pass `:silent`.)*

11. **Unsupervised `spawn` for side effects (line 49).** Failures are invisible, nothing is retried, and in-flight emails are lost on shutdown. Use `Task.Supervisor.start_child/2` (or a job queue such as Oban if delivery must be reliable).

12. **The struct goes straight to `Repo.insert` with no changeset.** Schema-level validations and constraints are bypassed. Build a changeset and validate there.

### Style / idiom

13. **Nested `if`/`case` pyramid.** A `with` pipeline makes the success path read top-to-bottom and puts the failure cases in one place.

14. **Anonymous function in a pipe (line 55)** — `|> (fn text -> ... end).()` is a hard-to-read way to concatenate strings. Use string interpolation.

15. **Comments restate the code** (`# Get the role from params`, `# send the email`). Replace them with `@moduledoc`/`@doc`/`@spec`. Keep the one useful "why" comment (the provider lowercases emails).

16. **`params["nickname"] || email`** treats `""` as a real nickname. Treat blank strings as missing too.

## Improved version

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV/JSON source.
  """

  import Ecto.Changeset

  alias Accounts.{Repo, User}

  @roles %{"admin" => :admin, "member" => :member, "guest" => :guest}
  @min_age 18
  @max_age 120

  @type error_reason ::
          :invalid_role | :invalid_email | :invalid_age | :underage | Ecto.Changeset.t()

  @doc """
  Imports a single user from string-keyed `params`.

  ## Options

    * `:notify` - send a welcome email after a successful insert (default `false`)
  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, error_reason()}
  def import_user(params, opts \\ []) when is_map(params) do
    with {:ok, role} <- parse_role(params["role"]),
         {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         {:ok, user} <- insert_user(email, age, role, nickname(params["nickname"], email)) do
      if Keyword.get(opts, :notify, false), do: send_welcome(user)
      {:ok, user}
    end
  end

  defp parse_role(role) when is_map_key(@roles, role), do: {:ok, Map.fetch!(@roles, role)}
  defp parse_role(_role), do: {:error, :invalid_role}

  # The provider lowercases addresses before its uniqueness check, so match it here
  defp parse_email(email) when is_binary(email) and email != "", do: {:ok, String.downcase(email)}
  defp parse_email(_email), do: {:error, :invalid_email}

  defp parse_age(age) when is_integer(age), do: check_age(age)

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {age, ""} -> check_age(age)
      _ -> {:error, :invalid_age}
    end
  end

  defp parse_age(_age), do: {:error, :invalid_age}

  defp check_age(age) when age < @min_age, do: {:error, :underage}
  defp check_age(age), do: {:ok, min(age, @max_age)}

  defp nickname(nickname, _email) when is_binary(nickname) and nickname != "", do: nickname
  defp nickname(_nickname, email), do: email

  defp insert_user(email, age, role, nickname) do
    %User{}
    |> change(email: email, age: age, role: role, nickname: nickname)
    |> unique_constraint(:email)
    |> Repo.insert()
  end

  defp send_welcome(user) do
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn ->
      Mailer.deliver(welcome_email(user))
    end)
  end

  defp welcome_email(%User{nickname: nickname}) do
    "Hi #{nickname || "there"}, welcome! Enjoy your account."
  end
end
```

### Notes on the rewrite

- **`@roles` is a placeholder.** Fill it with the real role set from `User`'s schema. If `role` is an `Ecto.Enum` field, use `Ecto.Enum.mappings(User, :role)` to build it.
- **`unique_constraint(:email)` needs a unique index** on `users.email` (ideally on `lower(email)` or a `citext` column). If one doesn't exist yet, add it in a migration.
- **`Accounts.TaskSupervisor` must be started** in the application's supervision tree: `{Task.Supervisor, name: Accounts.TaskSupervisor}`.
- If `User` already has a changeset function with its own validations, call it instead of `change/2`.
- `Mailer.deliver/1` is still given a plain string, as in the original. If the mailer expects an email struct (e.g. Swoosh), build one in `welcome_email/1`.
- **Breaking API changes:** the `:return_id` and `:silent` options are removed (findings 9–10), and the error atoms are now specific instead of always `:invalid` (finding 8). Update callers that match on `{:error, :invalid}`.
