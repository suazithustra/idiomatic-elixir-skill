# Review: `Accounts.UserImporter`

## Findings

Ordered from most to least severe. Line numbers refer to `code-review-input.ex`.

**1. The age cap does nothing (lines 15–17).** A user imported with age 150 is stored as 150. In Elixir, `age = 120` inside the `if` creates a new variable that only exists inside that block, so the outer `age` is unchanged. The compiler warns about it ("variable "age" is unused"). Fix: `min(age, 120)`.

**2. Roles are turned into atoms straight from the input (line 8).** `String.to_atom(params["role"])` creates a new atom for every distinct role string. Atoms are never freed and the BEAM (the Erlang virtual machine) has a fixed atom limit of about one million by default, so a large or hostile import file can crash the whole node. It also accepts any role string, and because it sits outside the `try`, a row with no role raises in the caller instead of returning an error. Fix: map the allowed role strings to atoms explicitly and reject anything else.

**3. Every JSON row is rejected (line 13).** `String.to_integer/1` only accepts strings. JSON decoders give `"age": 30` as the integer `30`, which raises `ArgumentError`, and the rescue turns that into `{:error, :invalid}`. The module says it handles JSON, so this path never works. Fix: accept integers as they are and parse strings with `Integer.parse/1`.

**4. `rescue _ ->` hides every failure as `:invalid` (lines 38–39).** Database outages, bugs in this module and duplicate emails all come back as `{:error, :invalid}`. Duplicates are hit by this specifically: the code inserts a bare struct with no changeset (Ecto's structure for validating and tracking changes), so a unique-index violation raises `Ecto.ConstraintError` instead of returning an error tuple, and the rescue relabels it. That also makes the `_ -> {:error, :insert_failed}` branch on line 32 almost unreachable. Fix: remove the `try`, validate each field with pattern matching inside a `with`, insert through a changeset with `unique_constraint(:email)` so duplicates return `{:error, changeset}`, and let infrastructure failures raise.

**5. The welcome email never sends (line 49).** `user[:name]` uses the Access protocol (the `[]` lookup syntax), which structs do not implement, so it raises `UndefinedFunctionError` on every call. Because it runs inside `spawn`, the only trace is a crash line in the logs. The importer also never sets a `name`; it sets `nickname`. Fix: use `user.nickname`.

**6. The email process is unsupervised (line 45).** With a bare `spawn`, nothing notices if delivery fails, and an email in flight is lost when the node shuts down. Fix: start it with `Task.Supervisor.start_child/2` under a supervisor in the application tree. If lost welcome emails matter to the business, I would use a persistent job queue such as Oban instead, because it retries and survives restarts.

**7. `:return_id` changes the return type (line 30).** Depending on an option, success returns either `{:ok, user}` or a bare id, so callers have to handle three shapes. Fix: always return `{:ok, user}`; a caller that needs the id reads `user.id`.

**8. `:notify` and `:silent` overlap (line 26).** `:silent` only exists to cancel `:notify`. Fix: keep `:notify` alone.

**9. Blank CSV cells slip through (lines 12, 19, 21).** CSV parsers return `""` for empty cells. An empty email passes the `is_binary(email)` check, and an empty nickname wins over the `|| email` fallback, so the user gets a blank nickname. The `is_binary(email)` check is also always true at that point, because `String.downcase/1` would already have raised on a non-string. Fix: reject blank emails and treat a blank nickname as missing.

**10. Style (lines 2, 5, 7, 44, 51).** Piping into an anonymous function on line 51 is harder to read than string interpolation. The comments on lines 2 and 5 belong in `@moduledoc` and `@doc`; the ones on lines 7 and 44 repeat the code and can go. The comment on line 11 explains a reason and should stay.

## Changes callers will notice

- `:return_id` and `:silent` are gone. Callers passing `notify: true, silent: true` will now send an email, so search the call sites for both options.
- Errors are now specific: `:invalid_email`, `:invalid_age`, `:underage`, `:invalid_role`, or an `Ecto.Changeset` for insert failures. I chose this over keeping a single `:invalid` because an import job needs to report why each row failed. Callers matching `{:error, :invalid}` or `{:error, :insert_failed}` need updating.
- Database errors now raise instead of returning `{:error, :invalid}`.

## Assumptions to check before merging

- `@roles` lists placeholder roles (`admin`, `member`). Replace them with the real set.
- `unique_constraint(:email)` assumes the index has Ecto's default name, `users_email_index`. Pass `name:` if it differs.
- `Accounts.TaskSupervisor` must be added to the application's supervision tree: `{Task.Supervisor, name: Accounts.TaskSupervisor}`.
- `Mailer` and the plain-string body from `welcome_email/1` are kept as in the original. `Mailer` is not aliased, so it resolves to a top-level `Mailer` module; if the app uses Swoosh, `deliver/1` needs an email struct with a recipient, not a string.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  import Ecto.Changeset, only: [change: 1, unique_constraint: 2]

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120
  @roles %{"admin" => :admin, "member" => :member}

  @doc """
  Validates `params` and inserts a user.

  ## Options

    * `:notify` - send a welcome email after the insert. Defaults to `false`.

  Returns `{:ok, user}`, `{:error, reason}` when a field is invalid, or
  `{:error, changeset}` when the insert fails (for example, a duplicate email).
  """
  @spec import_user(map(), keyword()) :: {:ok, %User{}} | {:error, atom() | Ecto.Changeset.t()}
  def import_user(params, opts \\ []) do
    with {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         {:ok, role} <- parse_role(params["role"]),
         nickname = parse_nickname(params["nickname"], email),
         {:ok, user} <- insert_user(%User{email: email, age: age, role: role, nickname: nickname}) do
      if Keyword.get(opts, :notify, false), do: send_welcome(user)
      {:ok, user}
    end
  end

  # The provider lowercases addresses before its uniqueness check, so match it here.
  defp parse_email(email) when is_binary(email) do
    case email |> String.trim() |> String.downcase() do
      "" -> {:error, :invalid_email}
      email -> {:ok, email}
    end
  end

  defp parse_email(_email), do: {:error, :invalid_email}

  # CSV rows carry the age as a string, JSON documents usually as an integer.
  defp parse_age(age) when is_integer(age) and age >= @min_age, do: {:ok, min(age, @max_age)}
  defp parse_age(age) when is_integer(age), do: {:error, :underage}

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(String.trim(age)) do
      {age, ""} -> parse_age(age)
      _ -> {:error, :invalid_age}
    end
  end

  defp parse_age(_age), do: {:error, :invalid_age}

  defp parse_role(role) when is_map_key(@roles, role), do: {:ok, Map.fetch!(@roles, role)}
  defp parse_role(_role), do: {:error, :invalid_role}

  # CSV rows carry an empty string for a missing column.
  defp parse_nickname(nickname, _email) when is_binary(nickname) and nickname != "", do: nickname
  defp parse_nickname(_nickname, email), do: email

  defp insert_user(user) do
    user
    |> change()
    |> unique_constraint(:email)
    |> Repo.insert()
  end

  defp send_welcome(user) do
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn ->
      user |> welcome_email() |> Mailer.deliver()
    end)
  end

  defp welcome_email(user), do: "Hi #{user.nickname}, welcome! Enjoy your account."
end
```

## Verification

Findings 1, 3 and 5 were confirmed by running the original expressions on Elixir 1.20.3. The improved module compiles without warnings, passes `mix format --check-formatted`, and passes 5 tests run against stub versions of Ecto, the repo and the mailer (`check/improved_test.exs`). It has not been run against a real database.
