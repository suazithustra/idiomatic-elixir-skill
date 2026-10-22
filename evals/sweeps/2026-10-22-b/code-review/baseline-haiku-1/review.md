# Review: `Accounts.UserImporter`

## Findings

1. **Age clamp never takes effect (correctness).** `if age > 120 do age = 120 end` rebinds `age` inside the `if` block. Elixir does not leak that binding out, so an age of 150 is stored as 150. Fix: `min(age, 120)`.

2. **Atom creation from untrusted input (security / BEAM resource).** `String.to_atom(params["role"])` creates a new atom for every distinct input string. Atoms are never garbage-collected, so an importer fed arbitrary data can exhaust the atom table. It also sits outside the `try`, so a `nil` role raises instead of returning `{:error, :invalid}`. Fix: `String.to_existing_atom/1` inside a validating function, or better, a whitelist or `Ecto.Enum` on the schema.

3. **Over-broad `rescue` (error handling).** `rescue _ -> {:error, :invalid}` wraps the whole function, including `Repo.insert/1` and `send_welcome/1`. Genuine failures such as DB connection errors are reported as "invalid input", which is misleading and hides real faults. Fix: parse inputs with explicit `{:ok, _} | {:error, _}` returns and let infrastructure errors raise.

4. **Type checks happen after the work they guard (readability / correctness).** `String.downcase(params["email"])` runs before `is_binary(email)`. A `nil` email only avoids a crash because the rescue catches it. The check should come first, in its own function.

5. **Broken welcome email (correctness).** `user[:name]` uses the Access protocol on a struct. Structs do not implement Access, so this raises at runtime. `User` also has no `:name` field in the fields this module sets; `nickname` is the field in use. Fix: `user.nickname`.

6. **Pointless pipe into an anonymous function (idiom).** `greeting |> (fn text -> ... end).()` does nothing useful. Interpolation expresses the same thing directly.

7. **Mixed return shapes (API design).** With `return_id: true` the function returns a bare id; otherwise it returns `{:ok, user}`. Callers must know which shape to expect. This is kept for compatibility, but it is worth splitting into two functions (for example `import_user/2` and `import_user_id/2`) or documenting it in `@doc`.

8. **Fire-and-forget `spawn` (reliability).** The welcome email is started with bare `spawn/1`. Failures are invisible and the process is unsupervised. Prefer `Task.Supervisor.start_child/2` under the application's supervision tree. `Task.start/1` is a smaller improvement.

9. **Nested `if` and `&&` for control flow (idiom).** `if is_binary(email) && age >= 18` mixes boolean operators and nests a `case` inside an `if`/`else`. A `with` chain flattens this and makes each failure explicit.

10. **Comments restate the code (style).** "Get the role from params", "send the email", and "This module imports users..." describe what the code already says. Keep the comment about the provider lowercasing addresses, since it explains a non-obvious reason. Move the module description to `@moduledoc`.

11. **Catch-all `_ ->` in `case` (robustness).** `Repo.insert/1` returns `{:ok, _}` or `{:error, changeset}`. Matching `_` hides any other shape. Match `{:error, _changeset}` explicitly.

## Behavior changes to confirm

- Exceptions from `Repo.insert/1` and similar calls now propagate instead of returning `{:error, :invalid}`. This is intentional but affects callers.
- `String.to_existing_atom/1` rejects role strings whose atom does not already exist. This is safe only if every valid role is defined as an atom somewhere in the codebase (for example in `User`).
- `welcome_email/1` now greets by `nickname`, not `name`. Before, the greeting always fell back to "there" because the struct access crashed.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc "Imports users from an external CSV/JSON source."

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from `params`.

  Options:

    * `:notify` - send a welcome email (default `false`)
    * `:silent` - suppress the welcome email even when `:notify` is set
    * `:return_id` - return the inserted id instead of `{:ok, user}`
  """
  def import_user(params, opts \\ []) do
    with {:ok, attrs} <- parse_attrs(params),
         {:ok, user} <- insert_user(attrs) do
      if opts[:notify] and not opts[:silent], do: send_welcome(user)

      if opts[:return_id], do: user.id, else: {:ok, user}
    end
  end

  defp parse_attrs(params) do
    with {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         {:ok, role} <- parse_role(params["role"]) do
      {:ok, %{email: email, age: age, role: role, nickname: params["nickname"] || email}}
    end
  end

  # The provider lowercases addresses before its uniqueness check, so match it here
  defp parse_email(email) when is_binary(email), do: {:ok, String.downcase(email)}
  defp parse_email(_), do: {:error, :invalid}

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {age, ""} when age >= @min_age -> {:ok, min(age, @max_age)}
      _ -> {:error, :invalid}
    end
  end

  defp parse_age(_), do: {:error, :invalid}

  # Only accepts roles whose atoms already exist, so input cannot create new atoms
  defp parse_role(role) when is_binary(role) do
    {:ok, String.to_existing_atom(role)}
  rescue
    ArgumentError -> {:error, :invalid}
  end

  defp parse_role(_), do: {:error, :invalid}

  defp insert_user(attrs) do
    case Repo.insert(struct!(User, attrs)) do
      {:ok, user} -> {:ok, user}
      {:error, _changeset} -> {:error, :insert_failed}
    end
  end

  defp send_welcome(user) do
    Task.start(fn -> Mailer.deliver(welcome_email(user)) end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
```

Notes on the rewrite:

- `parse_age/1` rejects anything under 18 with `{:error, :invalid}`, so the old `is_binary(email) && age >= 18` check moves into the parsing step.
- `Integer.parse/1` replaces `String.to_integer/1`, so malformed ages return an error instead of raising.
- `Task.start/1` is used for brevity. For production, prefer `Task.Supervisor.start_child/2` with a named supervisor.
- `Mailer` is referenced as in the original. Add an `alias` if it lives under a namespace.
