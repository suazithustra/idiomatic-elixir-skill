# Review: `Accounts.UserImporter`

Rules are from `idiomatic-elixir` (`SKILL.md`) and its references `ecto-phoenix.md` and `processes.md`.

## Findings

### 1. The whole function is wrapped in `try/rescue` (lines 10, 42–44)

`rescue _ -> {:error, :invalid}` turns every exception into the same answer, including typos and bugs in this module. A caller cannot tell a bad age from a crash. Rule: `rescue` only around third-party code with no non-raising version, and never `rescue _ ->` around a whole function. Fix: call the non-raising versions and let real bugs raise.

### 2. `String.to_atom/1` on external input (line 8)

`String.to_atom(params["role"])` creates an atom for any string an importer file contains. Atoms are never garbage-collected, so this can exhaust the VM's atom table (the virtual machine's fixed limit on atoms). It also raises on a missing role, and that raise happens outside the `try`. Rule: convert external strings with a fixed list, or with `Ecto.Enum` in the schema. Fix: the role is cast by `User.changeset/2` through an `Ecto.Enum` field.

### 3. `String.to_integer/1` raises on bad input (line 13)

A non-numeric age raises and is then swallowed by finding 1. Rule: call the non-raising version. Fix: `clamp_age/1` uses `Integer.parse/1`, and an unparseable value is passed on so the changeset reports it as invalid.

### 4. The clamp to 120 never takes effect (lines 15–17)

`age = 120` inside `if` is a new variable that dies at the `end`. An age of 150 stays 150, and the compiler warns that the variable is unused. Rule: assign the result of `if`, or use a function call. Fix: `min(age, @max_age)` in `clamp_age/1`.

### 5. Single-step pipe and a crash on a missing email (line 12)

`params["email"] |> String.downcase()` pipes one step, which the rules say to write as a plain call. It also raises `FunctionClauseError` when the email is missing, and that error is then swallowed by finding 1. Fix: `normalize_email/1` with a clause for binaries and one for everything else.

### 6. `&&` on booleans and a pointless `is_binary/1` check (line 21)

`is_binary(email) && age >= 18` joins two booleans, so the rule says `and`. The `is_binary/1` check is also dead code, since line 12 would already have raised on a non-string. Fix: the age rule moves into `validate_number/3` in the changeset, and the check goes away.

### 7. A struct is inserted directly, and the duplicate check is a lookup before the insert (lines 22–24)

`%User{email: ..., age: ..., role: ...}` passed to `Repo.insert/1` skips validation entirely. `Repo.get_by(User, email: email) == nil` followed by an insert is also a race: two imports of the same email can both pass the check. Rule: insert a changeset, and declare `unique_constraint/3` so a duplicate returns `{:error, changeset}`. Fix: `build_changeset/1` and `User.changeset/2` (see the note below the code).

### 8. The catch-all `_ ->` hides the insert error (lines 33–34)

`_ -> {:error, :insert_failed}` replaces the changeset with a generic reason. Rule: match the error shape explicitly. Fix: `Repo.insert/1` returns `{:error, changeset}`, and `with` passes it on unchanged.

### 9. Different failures return the same reason (lines 37, 40)

A taken email, a missing email, and an age under 18 all return `{:error, :invalid}`. A caller cannot tell them apart. Rule: different failures need different reasons. Fix: the changeset carries one error per invalid field.

### 10. `return_id` changes the return shape (line 31)

`if opts[:return_id], do: user.id, else: {:ok, user}` returns a bare integer in one mode and a tuple in the other. Rule: give each function one return shape. Fix: `import_user/2` always returns `{:ok, user}`. Callers that need the id read `user.id`. This removes the `:return_id` option, which is a change for any caller that passes it.

### 11. Two overlapping booleans for notification (line 27)

`opts[:notify] && !opts[:silent]` combines `notify: true, silent: true`, a combination that means nothing: silent wins. Rule: use one atom-valued option instead of overlapping booleans. Fix: `notify: :welcome | :none`, defaulting to `:none`. This removes the `:silent` option, which is a change for any caller that passes it. `Keyword.validate!/2` rejects unknown options, so a leftover `silent:` fails loudly.

### 12. `user[:name]` on a struct (line 53)

Structs do not implement `Access`, so `user[:name]` raises `UndefinedFunctionError`. The struct built on line 22 also has no `name` field, so the greeting was never reachable. The call runs inside a `spawn`, so the failure is silent and no welcome email is sent. Rule: read struct fields with dot access. Fix: the greeting uses `user.nickname`, which the import always sets (it falls back to the email).

### 13. Bare `spawn/1` for the welcome email (line 49)

A spawned process has no supervisor, so it is not restarted, not shut down in order, and not visible to tools such as Observer. Rule: start one-off work under `Task.Supervisor`. Fix: `Task.Supervisor.start_child/2` under `Accounts.TaskSupervisor`. The closure now captures only the finished message string, not the whole `user` struct.

### 14. Piping into an anonymous function (line 55)

`greeting |> (fn text -> text <> " Enjoy your account." end).()` is the form the rules forbid. The string is also built by concatenation where interpolation reads better. Fix: one interpolated string.

### 15. Comments that restate the code, and docs in comments (lines 2, 5, 7, 48)

`# Get the role from params`, `# send the email`, and similar comments repeat what the next line says, so they go. The module and function descriptions belong in `@moduledoc` and `@doc`. The comment on line 11 explains a reason the code cannot show, so it stays.

### 16. One function does parsing, validation, lookup, insert, and notification (lines 6–45)

`import_user/2` is 40 lines with three levels of nesting. Rule: a public function reads as a short sequence of named steps, with details in private functions. Fix: `import_user/2` is now a `with` over `Repo.insert/1`, and each step is a private function.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV (comma-separated values) or JSON (JavaScript Object Notation) source.
  """

  alias Accounts.{Repo, User}

  @max_age 120

  @doc """
  Imports one user from string-keyed `params`.

  Returns `{:ok, user}` or `{:error, changeset}`. The changeset names each
  invalid field, including an email that is already taken.

  ## Options

    * `:notify` - `:welcome` sends a welcome email after the insert. Defaults to `:none`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: :none)

    with {:ok, user} <- params |> build_changeset() |> Repo.insert() do
      notify(user, opts[:notify])
      {:ok, user}
    end
  end

  defp build_changeset(params) do
    # The provider lowercases addresses before its uniqueness check, so match it here
    email = normalize_email(params["email"])

    attrs = %{
      email: email,
      age: clamp_age(params["age"]),
      role: params["role"],
      nickname: params["nickname"] || email
    }

    User.changeset(%User{}, attrs)
  end

  defp normalize_email(email) when is_binary(email), do: String.downcase(email)
  defp normalize_email(_email), do: nil

  defp clamp_age(age) when is_integer(age), do: min(age, @max_age)

  defp clamp_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {value, ""} -> clamp_age(value)
      _ -> age
    end
  end

  defp clamp_age(age), do: age

  defp notify(user, :welcome), do: send_welcome(user)
  defp notify(_user, :none), do: :ok

  defp send_welcome(user) do
    message = "Hi #{user.nickname}, welcome! Enjoy your account."

    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(message) end)
  end
end
```

## Notes on the code above

- `User.changeset/2` must exist and do the validation the old code did by hand. A minimal version:

  ```elixir
  field :role, Ecto.Enum, values: [:admin, :editor, :member]   # placeholder values

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :age, :role, :nickname])
    |> validate_required([:email, :age, :role])
    |> validate_number(:age, greater_than_or_equal_to: 18)
    |> unique_constraint(:email)
  end
  ```

  `unique_constraint/3` needs a unique index on `email` in the database. The role values are a placeholder, since the real set is not in the file reviewed.
- `Accounts.TaskSupervisor` must be started in the application's supervision tree, for example `{Task.Supervisor, name: Accounts.TaskSupervisor}`.
- Callers that pass `:return_id` or `:silent` now get an error from `Keyword.validate!/2`. Callers that need the id read `user.id` from the returned tuple.
- Nothing has been compiled or run. `mix format --check-formatted` and `mix compile` should run on this file once the project's `User` module is in place.
