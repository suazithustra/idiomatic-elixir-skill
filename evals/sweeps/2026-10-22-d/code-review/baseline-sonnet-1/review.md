# Review: `Accounts.UserImporter`

## Findings

### Bugs
1. **`age = 120` inside `if` never takes effect.** Elixir variables don't leak out of `if` blocks (and the compiler warns). Ages above 120 are passed through unclamped. Fix: `age = min(age, 120)`.
2. **`String.to_atom(params["role"])` on external input.** Atoms are never garbage-collected, so untrusted input can exhaust the atom table and crash the VM. It also raises on a missing role (`nil`) and happens *outside* the `try`, so the function crashes instead of returning `{:error, _}`. Fix: whitelist roles with a map lookup.
3. **`welcome_email/1` uses `user[:name]` on a struct.** Structs don't implement `Access`, so this raises `UndefinedFunctionError` inside the spawned process. The failure is silent and no welcome email is ever sent. Use `user.name` (if the field exists) or `Map.get/3`. `User` is built with `nickname`, not `name`, so the greeting probably wanted `nickname`.
4. **`is_binary(email)` check is useless and misplaced.** `String.downcase/1` has already raised on a non-binary by then, so the check can never be false. The `rescue` then hides the real cause.
5. **Check-then-insert race.** `Repo.get_by` followed by `Repo.insert` is not atomic, so two concurrent imports of the same email can both pass the check. Rely on a DB unique index plus `unique_constraint/2` in a changeset, and handle the error tuple.
6. **`Mailer` isn't aliased or qualified.** It resolves to the top-level `Mailer` module, which is probably not intended, and the call is not checked.

### Design / idiom
7. **Blanket `try/rescue _ ->`** swallows every exception (including programmer bugs, DB connection errors) and turns them into `:invalid`. Replace with explicit parsing (`Integer.parse/1`) and a `with` chain that returns tagged errors.
8. **Inconsistent return shapes.** `opts[:return_id]` makes the function return a bare id instead of `{:ok, user}`, so callers can't pattern-match uniformly. A duplicate email returns `:invalid` rather than a distinguishable `:email_taken`. Both are fixed below. (`:return_id` is dropped. Callers can use `user.id`. Say so if it must stay.)
9. **Error information is discarded.** `_ -> {:error, :insert_failed}` throws away the changeset. Return `{:error, changeset}`.
10. **`spawn` for email is unsupervised and unlinked.** Failures vanish. Use `Task.Supervisor.start_child/2` (assumes `Accounts.TaskSupervisor` is in the supervision tree).
11. **`opts[:notify] && !opts[:silent]`** is clunky, and `&&`/`!` on non-booleans is non-idiomatic. Use `Keyword.get/3` with `and`/`not`, or collapse into one option.
12. **Deeply nested `if/case/if`** flattened into a `with` pipeline with small private functions.
13. **`welcome_email/1` builds a string through an anonymous function pipe.** `greeting |> (fn ... end).()` is needless. Use interpolation.
14. **Comments restate the code** ("Get the role from params", "send the email"). Replace with `@moduledoc`/`@doc` and keep only the comment explaining *why* (the provider's downcase).
15. **No handling for `nil`/non-string `email` or `age`**; `String.to_integer` raises on `"abc"` or `nil`. Handled via `Integer.parse/1`.
16. **Missing `@spec`s and docs.**

## Improved code

Assumptions: `User` has `email`, `age`, `role`, `nickname` fields; the DB has a unique index on `email`; `Accounts.TaskSupervisor` is started; `Mailer.deliver/1` exists.

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV/JSON source.
  """

  import Ecto.Changeset, only: [change: 2, unique_constraint: 2]

  alias Accounts.{Repo, User}

  @roles %{"admin" => :admin, "member" => :member, "guest" => :guest}
  @min_age 18
  @max_age 120

  @type error :: :invalid | {:invalid, atom()} | Ecto.Changeset.t()

  @doc """
  Imports a single user from string-keyed `params`.

  Options:

    * `:notify` - send a welcome email after insert (default `false`)
    * `:silent` - suppresses the welcome email even when `:notify` is set
  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, error()}
  def import_user(params, opts \\ []) when is_map(params) do
    with {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         {:ok, role} <- parse_role(params["role"]),
         {:ok, user} <- insert(email, age, role, params["nickname"] || email) do
      maybe_send_welcome(user, opts)
      {:ok, user}
    end
  end

  # The provider lowercases addresses before its uniqueness check, so match it here.
  defp parse_email(email) when is_binary(email), do: {:ok, String.downcase(email)}
  defp parse_email(_), do: {:error, {:invalid, :email}}

  defp parse_age(age) when is_integer(age), do: validate_age(age)

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {int, ""} -> validate_age(int)
      _ -> {:error, {:invalid, :age}}
    end
  end

  defp parse_age(_), do: {:error, {:invalid, :age}}

  defp validate_age(age) when age >= @min_age, do: {:ok, min(age, @max_age)}
  defp validate_age(_), do: {:error, {:invalid, :age}}

  defp parse_role(role) do
    case Map.fetch(@roles, role) do
      {:ok, _} = ok -> ok
      :error -> {:error, {:invalid, :role}}
    end
  end

  defp insert(email, age, role, nickname) do
    %User{}
    |> change(email: email, age: age, role: role, nickname: nickname)
    |> unique_constraint(:email)
    |> Repo.insert()
    |> case do
      {:ok, user} -> {:ok, user}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp maybe_send_welcome(user, opts) do
    if Keyword.get(opts, :notify, false) and not Keyword.get(opts, :silent, false) do
      Task.Supervisor.start_child(Accounts.TaskSupervisor, fn ->
        Mailer.deliver(welcome_email(user))
      end)
    end

    :ok
  end

  defp welcome_email(user) do
    "Hi #{user.nickname || "there"}, welcome! Enjoy your account."
  end
end
```

Note: the `case` in `insert/4` is an identity mapping and can be dropped (just end the pipe at `Repo.insert()`); it is left out of nothing important, so simplify by removing it if you prefer. A duplicate email now surfaces as `{:error, %Ecto.Changeset{}}` with an `email` error rather than a generic `:invalid`.
