# Review: `Accounts.UserImporter`

## Findings

1. **Atom exhaustion and crash on untrusted input (high).** `String.to_atom(params["role"])` runs outside the `try`, so a `nil` role raises `FunctionClauseError` (or `ArgumentError` for non-binaries) before any rescue. Worse, converting arbitrary imported strings to atoms lets an external file grow the atom table until the VM runs out, and atoms are never garbage collected. Fix: map known role strings through a fixed table and return `{:error, :invalid}` for anything else.

2. **The age clamp does nothing (high).** `if age > 120 do age = 120 end` rebinds `age` inside an `if`. Elixir does not leak rebindings out of `if`, so `age` stays above 120 and the clamp is dead code. Fix: compute `min(age, 120)` as an expression.

3. **Blanket `rescue _ ->` hides bugs (high).** Any exception, including a programming error in `Repo` or `Mailer` setup, becomes `{:error, :invalid}`. Callers cannot tell bad input from a broken system, and failures disappear. Fix: validate inputs explicitly with `Integer.parse/1` and pattern matching, and let unexpected exceptions raise. This drops the old behaviour of rescuing DB exceptions. That is a deliberate change; if the importer must keep running past DB errors, rescue at the caller that owns the batch loop.

4. **Check-then-insert race (medium).** `Repo.get_by` followed by `Repo.insert` is not atomic. Two concurrent imports of the same email can both pass the check. The real guard is a unique index on `users.email`; the insert should handle that constraint, not a prior read. Left as is here because the schema is not in the input, but noted in the code comments.

5. **Inconsistent return shape (medium).** With `return_id: true` the function returns a bare integer id; otherwise `{:ok, user}`. Callers have to branch on the option to know what they got. Fix: always return `{:ok, id}` or `{:ok, user}` tuples. This is an API change, so check callers of `return_id:`.

6. **Welcome email reads a field the struct does not have (medium).** `user[:name]` uses the `Access` behaviour, which `User` structs do not implement, so it raises `UndefinedFunctionError`. The import never sets a `name` field either. Fix: `Map.get(user, :name) || "there"` reads the field without crashing. Confirm which field is intended.

7. **Unsupervised `spawn` for mail delivery (low).** `spawn/1` gives no crash reporting and no supervision. `Task.start/1` at least logs crashes. If the app has a `Task.Supervisor`, use `Task.Supervisor.start_child/2`.

8. **Pipe into an anonymous function (low).** `greeting |> (fn text -> ... end).()` is a roundabout way to concatenate strings. An interpolated string is clearer.

9. **Dead nil-check ordering (low).** `String.downcase/1` runs before the `is_binary(email)` check, so a missing email relies on the rescue to be rejected. Matching `%{"email" => email} when is_binary(email)` states the requirement directly.

10. **Comments narrate the code (low).** "Get the role from params", "send the email", and similar comments repeat what the code says. The one useful comment, about the provider lowercasing addresses, moves next to `fetch_email/1`. The module also needs a `@moduledoc` in place of the header comment.

11. **Error reasons are collapsed (low).** Every failure returns `:invalid`, including a DB insert failure, which is `:insert_failed`. The original already did this for insert failures, and the new version keeps `:insert_failed` for that case.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV/JSON source.

  Returns `{:ok, user}` on success, or `{:ok, id}` when the `:return_id`
  option is set. Returns `{:error, :invalid}` for bad input or a duplicate
  email, and `{:error, :insert_failed}` when the database rejects the insert.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  # Keys are the role strings the source sends. Adjust to match the roles in User.
  @roles %{"admin" => :admin, "member" => :member}

  def import_user(params, opts \\ []) do
    with {:ok, email} <- fetch_email(params),
         {:ok, age} <- parse_age(params["age"]),
         {:ok, role} <- parse_role(params["role"]),
         :ok <- ensure_unique(email),
         {:ok, user} <- insert_user(params, email, age, role) do
      maybe_send_welcome(user, opts)
      format_result(user, opts)
    end
  end

  # The provider lowercases addresses before its uniqueness check, so match it here.
  defp fetch_email(%{"email" => email}) when is_binary(email),
    do: {:ok, String.downcase(email)}

  defp fetch_email(_params), do: {:error, :invalid}

  defp parse_age(value) when is_binary(value) do
    case Integer.parse(value) do
      {age, ""} when age >= @min_age -> {:ok, min(age, @max_age)}
      _ -> {:error, :invalid}
    end
  end

  defp parse_age(_value), do: {:error, :invalid}

  defp parse_role(role) do
    case Map.fetch(@roles, role) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, :invalid}
    end
  end

  # The unique index on users.email is the real guard against concurrent
  # imports. This read only avoids a pointless insert in the common case.
  defp ensure_unique(email) do
    if Repo.get_by(User, email: email), do: {:error, :invalid}, else: :ok
  end

  defp insert_user(params, email, age, role) do
    attrs = %{email: email, age: age, role: role, nickname: params["nickname"] || email}

    case Repo.insert(struct(User, attrs)) do
      {:ok, user} -> {:ok, user}
      {:error, _changeset} -> {:error, :insert_failed}
    end
  end

  defp maybe_send_welcome(user, opts) do
    if opts[:notify] && !opts[:silent], do: send_welcome(user)
  end

  defp format_result(user, opts) do
    if opts[:return_id], do: {:ok, user.id}, else: {:ok, user}
  end

  defp send_welcome(user) do
    Task.start(fn -> Mailer.deliver(welcome_email(user)) end)
  end

  defp welcome_email(user) do
    name = Map.get(user, :name) || "there"
    "Hi #{name}, welcome! Enjoy your account."
  end
end
```
