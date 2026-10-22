# Review: `Accounts.UserImporter`

## Findings

### Bugs / correctness

1. **The age clamp does nothing (line 15–17).** `age = 120` inside `if` binds a new variable scoped to that block. The outer `age` is unchanged, so ages above 120 are stored as-is, and the compiler warns that the variable is unused. Bind the result of the expression instead: `age = min(age, 120)`.

2. **`String.to_atom/1` on external input (line 8).** Every distinct `role` string in an import file creates a new atom. Atoms are never garbage-collected, so a large or hostile file can exhaust the atom table and crash the VM. It also accepts any role at all (`"superadmin"`, `"lol"`). Map from an explicit allow-list of strings to atoms instead.

3. **Role parsing sits outside the `try` (line 8).** A missing `role` makes `String.to_atom(nil)` raise, and that raise escapes the function. A missing `age` gets `{:error, :invalid}`, so the same kind of bad input fails in two different ways depending on which field is missing.

4. **The `is_binary(email)` check can never be false (line 21).** `String.downcase/1` on line 12 has already raised on a non-binary email, so the check is dead code. Its intent (rejecting rows with no email) is only met by accident, through the catch-all `rescue`.

5. **`welcome_email/1` always crashes (line 49).** `user[:name]` uses the Access protocol, which structs don't implement, so this raises `UndefinedFunctionError`. The struct also has no `:name` field; the code builds it with `:nickname`. Because the crash happens inside a bare `spawn`, nobody sees it, and no welcome email is ever sent.

6. **`String.to_integer/1` assumes `age` is a string.** The module says it imports CSV *or JSON*. JSON decoders give integers, so `String.to_integer(30)` raises, and the rescue turns a valid row into `{:error, :invalid}`. Decimal strings like `"30.0"` and stray whitespace also raise.

7. **`Mailer` is not aliased or fully qualified.** It resolves to the top-level `Mailer` module, which probably doesn't exist (it is more likely `Accounts.Mailer` or `MyApp.Mailer`). You won't see this until runtime, and the unsupervised `spawn` hides the failure there too.

### Error handling & API design

8. **A blanket `rescue _ ->` hides real failures (lines 38–40).** It turns every exception into `{:error, :invalid}`: parse errors, but also DB connection errors, constraint violations raised by Ecto, and bugs in this module (findings 1–6 hid behind it). Use non-raising functions (`Integer.parse/1`, pattern matching) and a `with` chain. Let truly unexpected errors crash.

9. **The return type depends on an option (line 30).** With `return_id: true` the function returns a bare id; otherwise it returns `{:ok, user}`. Errors are always tuples. So with `return_id: true` callers have to match `{:error, _}` and a bare integer, which breaks `with` and `case` conventions. Always return `{:ok, user}` and let the caller take `user.id`.

10. **Insert errors are thrown away (line 32–33).** `_ -> {:error, :insert_failed}` drops the changeset or reason, so an importer can't report *why* a row failed (for example, a duplicate email). Pass the `{:error, reason}` through.

11. **No changeset validation.** `Repo.insert(%User{...})` skips any validations and constraints that `User` declares (unique email, format, and so on). The age, email and role checks done by hand here belong in `User.changeset/2` or a dedicated import changeset. The improved version below keeps the struct insert so it doesn't assume an API that may not exist, but moving to a changeset is the recommended next step.

12. **Two flags for one behaviour (line 26).** `notify` and `silent` overlap (`notify: true, silent: true` means "don't notify"). Keep one option, `notify` (default `false`), and read it with `Keyword.get/3`.

### Concurrency

13. **Unsupervised `spawn` for email delivery (line 45).** Nothing supervises or logs the process. Failures vanish (see finding 5), and pending sends are lost on shutdown. Use `Task.Supervisor.start_child/2` under a supervisor in your application tree, or a job queue (for example Oban) if delivery must be reliable.

### Style / idiom

14. **Comments instead of docs.** Use `@moduledoc` and `@doc` for the module and its public function. Add a `@spec`. Most of the inline comments ("Get the role from params", "send the email") just repeat the code and can go. The comment about the provider lowercasing emails explains *why*, so it is worth keeping.

15. **Piping into an anonymous function (line 51).** `|> (fn text -> ... end).()` is awkward and needless. String interpolation reads better: `"Hi #{name}, welcome! Enjoy your account."`.

16. **`params["email"] |> String.downcase()`** is a single-step pipe. Write `String.downcase(email)`. (Minor; the bigger point is to pattern-match the email as a binary first.)

17. **A nickname that is an empty string is kept.** `params["nickname"] || email` treats `""` as a valid nickname. CSV sources often produce empty strings for missing columns, so treat blank as missing.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV/JSON source.
  """

  alias Accounts.{Mailer, Repo, User}

  # Explicit allow-list: never convert external strings with String.to_atom/1.
  @roles %{"admin" => :admin, "member" => :member, "guest" => :guest}
  @min_age 18
  @max_age 120

  @type error :: :invalid_email | :invalid_age | :underage | :invalid_role | term()

  @doc """
  Imports a single user from a map of string-keyed params.

  ## Options

    * `:notify` - send a welcome email after a successful insert (default: `false`)
  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, error()}
  def import_user(params, opts \\ []) when is_map(params) do
    with {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         {:ok, role} <- parse_role(params["role"]),
         user = %User{
           email: email,
           age: age,
           role: role,
           nickname: nickname(params["nickname"], email)
         },
         {:ok, user} <- Repo.insert(user) do
      if Keyword.get(opts, :notify, false), do: send_welcome(user)
      {:ok, user}
    end
  end

  # The provider lowercases addresses before its uniqueness check, so match it here
  defp parse_email(email) when is_binary(email) and email != "", do: {:ok, String.downcase(email)}
  defp parse_email(_), do: {:error, :invalid_email}

  defp parse_age(age) when is_integer(age), do: validate_age(age)

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(String.trim(age)) do
      {age, ""} -> validate_age(age)
      _ -> {:error, :invalid_age}
    end
  end

  defp parse_age(_), do: {:error, :invalid_age}

  defp validate_age(age) when age < @min_age, do: {:error, :underage}
  defp validate_age(age), do: {:ok, min(age, @max_age)}

  defp parse_role(role) do
    case Map.fetch(@roles, role) do
      {:ok, role} -> {:ok, role}
      :error -> {:error, :invalid_role}
    end
  end

  defp nickname(nickname, _email) when is_binary(nickname) and nickname != "", do: nickname
  defp nickname(_, email), do: email

  defp send_welcome(user) do
    # Requires `{Task.Supervisor, name: Accounts.TaskSupervisor}` in the supervision tree.
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn ->
      user |> welcome_email() |> Mailer.deliver()
    end)
  end

  defp welcome_email(%User{nickname: nickname}) do
    "Hi #{nickname || "there"}, welcome! Enjoy your account."
  end
end
```

### Notes on the rewrite

- **Behaviour changes callers must know about:**
  - The `:return_id` and `:silent` options are removed.
  - Error reasons are now specific (`:invalid_email`, `:invalid_age`, `:underage`, `:invalid_role`) instead of a single `:invalid`.
  - Insert failures return the Repo's own error (usually a changeset) instead of `:insert_failed`.
  - Ages above 120 are now actually clamped.
- `@roles` is a placeholder. Fill it with the real set of roles.
- `Accounts.Mailer` and `Accounts.TaskSupervisor` are assumed names. Adjust them to the real modules.
- `welcome_email/1` returns a string, as the original did. If `Mailer.deliver/1` expects an email struct (Swoosh/Bamboo), build one there with the recipient set to `user.email`.
- Recommended follow-up: move the validation into a `User.import_changeset/2` and call `Repo.insert(changeset)`, so DB constraints such as the unique email come back as changeset errors.
