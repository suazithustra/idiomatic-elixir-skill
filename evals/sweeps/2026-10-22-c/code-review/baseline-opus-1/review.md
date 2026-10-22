# Review: `Accounts.UserImporter`

## Findings

### Bugs and security

1. **Atom exhaustion from external input (line 8).** `String.to_atom(params["role"])` makes a new atom for every distinct role string in the import. Atoms are never garbage-collected, so a hostile or messy file can exhaust the atom table and crash the VM. It also accepts any role at all, such as `"superadmin"`. Check the role against an explicit allowlist instead.
2. **Role parsing runs outside the `try` (line 8).** A missing `"role"` key calls `String.to_atom(nil)`, which raises `FunctionClauseError` straight to the caller. The function never returns `{:error, :invalid}` in that case.
3. **The age cap does nothing (lines 15–17).** `age = 120` inside `if` rebinds a variable that only exists in the `if` block. The outer `age` does not change, so ages over 120 are stored as given. The compiler warns about this ("variable age is unused"). Use `min(age, 120)`.
4. **`welcome_email/1` always crashes (line 53).** `user[:name]` uses the Access protocol, which structs do not implement, so it raises `UndefinedFunctionError`. `User` also has no `:name` field (the import sets `:nickname`). Because the call runs inside `spawn`, the crash is silent and no welcome email is ever sent.
5. **`is_binary(email)` is checked too late (line 21).** `String.downcase/1` on line 12 has already raised for a non-binary email. The guard can never be false, and a missing email only gets handled because the blanket `rescue` catches it.
6. **Check-then-insert race (lines 24–25).** `Repo.get_by` followed by `Repo.insert` is not atomic. Two concurrent imports of the same email can both pass the check. Uniqueness must be enforced by a unique index plus `unique_constraint/2`, with the insert result handled.
7. **Blanket `rescue _` (lines 42–43).** It turns every exception into `{:error, :invalid}`, including DB connection errors, bugs and the `Access` crash above. Real failures are hidden and debugging gets harder. Parse and validate with functions that return tagged tuples, and let unexpected exceptions propagate.
8. **`String.to_integer/1` raises on normal bad input (line 13).** Values like `"abc"`, `" 30"`, `"30.0"` or `nil` raise instead of giving a validation error. Use `Integer.parse/1` and match on `{age, ""}`.

### Design and API

9. **Return shape changes with an option (line 31).** With `return_id: true` the function returns a bare id; otherwise it returns `{:ok, user}`. Callers have to know which option was passed to match the result, and the bare id loses the `{:ok, _}` / `{:error, _}` contract. Always return `{:ok, user}` and let callers take `user.id`.
10. **Misleading error reasons.** A duplicate email returns `{:error, :invalid}`, which looks the same as bad input. An insert failure throws away the changeset/reason (`_ -> {:error, :insert_failed}`). Return distinct, meaningful reasons (`:email_taken`, `:invalid_age`, `:underage`, `:invalid_role`, or the changeset).
11. **Overlapping options `:notify` and `:silent`.** The two flags express one decision. Keep `:notify` only.
12. **Unsupervised `spawn` for side effects (line 49).** Crashes are invisible, nothing is logged or retried, and the process is not tied to the application's shutdown. Use `Task.Supervisor.start_child/2` under a named supervisor, or better, a job queue such as Oban if delivery matters.
13. **`Mailer` is not aliased (line 49).** It resolves to a top-level `Mailer` module, which is probably meant to be `Accounts.Mailer`. Check this. It compiles with no error and fails only at runtime.

### Style

14. **Deeply nested `try`/`if`/`case`/`if`.** A `with` chain of small, named validation steps reads top to bottom and keeps the happy path in one place.
15. **Piping into an anonymous function (line 55).** `|> (fn text -> ... end).()` is noise. Use string interpolation.
16. **Comments that restate the code** ("Get the role from params", "send the email") add nothing. The module needs `@moduledoc`, plus `@doc` and `@spec` on the public function. The provider-lowercasing comment is useful and should stay.
17. **Unnecessary `<>` concatenation.** Interpolation (`"Hi #{name}, welcome!"`) is the idiomatic form.

## Improved version

Assumptions, which should be checked against the codebase:
- `users.email` has a unique index.
- `Accounts.TaskSupervisor` is started in the supervision tree.
- The mailer is `Accounts.Mailer`.
- The allowed roles are listed in `@roles`.

Breaking change: the `:return_id` and `:silent` options are removed.

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV/JSON source.
  """

  import Ecto.Changeset, only: [change: 2, unique_constraint: 2]

  alias Accounts.{Mailer, Repo, User}

  @roles %{"admin" => :admin, "member" => :member, "guest" => :guest}
  @min_age 18
  @max_age 120

  @type error_reason ::
          :invalid_email | :invalid_age | :underage | :invalid_role | Ecto.Changeset.t()

  @doc """
  Imports a single user from string-keyed `params`.

  ## Options

    * `:notify` - send a welcome email after a successful insert (default: `false`)
  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, error_reason()}
  def import_user(params, opts \\ []) when is_map(params) do
    with {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         {:ok, role} <- parse_role(params["role"]),
         {:ok, user} <- insert_user(email, age, role, params["nickname"] || email) do
      if Keyword.get(opts, :notify, false), do: send_welcome(user)
      {:ok, user}
    end
  end

  # The provider lowercases addresses before its uniqueness check, so match it here.
  defp parse_email(email) when is_binary(email) and email != "", do: {:ok, String.downcase(email)}
  defp parse_email(_), do: {:error, :invalid_email}

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {age, ""} when age >= @min_age -> {:ok, min(age, @max_age)}
      {_age, ""} -> {:error, :underage}
      _ -> {:error, :invalid_age}
    end
  end

  defp parse_age(_), do: {:error, :invalid_age}

  defp parse_role(role) do
    case Map.fetch(@roles, role) do
      {:ok, role} -> {:ok, role}
      :error -> {:error, :invalid_role}
    end
  end

  defp insert_user(email, age, role, nickname) do
    %User{}
    |> change(email: email, age: age, role: role, nickname: nickname)
    |> unique_constraint(:email)
    |> Repo.insert()
  end

  defp send_welcome(user) do
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn ->
      user |> welcome_email() |> Mailer.deliver()
    end)
  end

  defp welcome_email(%User{nickname: nickname}) do
    "Hi #{nickname || "there"}, welcome! Enjoy your account."
  end
end
```

Notes on the rewrite:
- A duplicate email now returns `{:error, changeset}` with `email: {"has already been taken", ...}` on the changeset, and the database enforces uniqueness atomically. If callers need an atom, map that changeset error to `:email_taken` in `insert_user/4`.
- Bad input never raises. Unexpected failures, such as the DB being down, propagate as they should.
- `welcome_email/1` keeps the original behaviour of building a string. If `Mailer.deliver/1` expects an email struct (for example Swoosh), build that here instead.
