# Review of `Accounts.UserImporter`

## Findings

1. **Atom exhaustion and crash on input** (rule: convert external strings to atoms with explicit clauses). `role = String.to_atom(params["role"])` creates an atom for any string, and raises on `nil`. This line is also outside the `try`, so a missing role crashes instead of returning `{:error, :invalid}`. Fix: `parse_role/1` with one clause per accepted role, returning `{:error, {:unknown_role, other}}`.

2. **`try/rescue` used to get a tuple** (rule: return tuples for expected failures; never `rescue _ ->`). `rescue _ -> {:error, :invalid}` hides every bug, including bugs in `Repo` and `Mailer`, and gives one reason for different failures. Fix: use `Integer.parse/1` and explicit error tuples, and remove the `try`.

3. **`String.to_integer/1` raises on bad input.** Replaced by `Integer.parse/1` in `parse_age/1`, which returns `{:error, {:invalid_field, "age"}}`.

4. **Rebinding inside `if` does not escape it.** `if age > 120 do age = 120 end` leaves `age` unchanged, so the cap never applies (and the compiler warns). Fix: `min(age, @max_age)`.

5. **Required keys read with `params["email"]` and checked later; `nil` fails far from the cause.** `params["email"] |> String.downcase()` raises on a missing email. Fix: match `"email"`, `"age"` and `"role"` in the function head and give the no-match case its own clause returning `{:error, :invalid_params}`.

6. **Dead check:** `is_binary(email)` runs after `String.downcase(email)`, which has already raised for a non-binary. The head guard `when is_binary(email)` replaces it.

7. **`&&` and `!` on booleans** (rule: `and`/`or`/`not` for booleans). `is_binary(email) && age >= 18` becomes `and`. The `opts[:notify] && !opts[:silent]` case is covered by finding 9.

8. **Hand-built validation and uniqueness check** (ecto-phoenix: validate with changesets). `%User{...}` passed to `Repo.insert/1` is not validated, and `Repo.get_by(...) == nil` before the insert is a race: two imports of the same email can both pass, and the second insert raises. Fix: `User.changeset/2` with `cast/3`, `validate_required/2` and `unique_constraint(:email)`, so a duplicate returns `{:error, changeset}`. This needs a unique index on `email`. Sketch below.

9. **Overlapping booleans** (`notify: true, silent: true` makes no sense). Keep only `:notify`, and check options with `Keyword.validate!/2`.

10. **One function, two return shapes.** `return_id: true` returns a bare id, otherwise `{:ok, user}`. Removed; callers read `user.id`. If an id-only variant is needed, write a separate function.

11. **`_ -> {:error, :insert_failed}` swallows the reason.** It turns every insert result into one error. The changeset error is returned as `{:error, changeset}`.

12. **Nested `if`/`case`/`if` in a long function** (rule: keep functions short, one level of detail). The body is split into `parse_age/1`, `parse_role/1`, `insert_user/2` and `maybe_notify/2`, chained in `with`.

13. **Bare `spawn/1` for fire-and-forget** (processes.md: supervise every long-lived process; send processes only the data they need). The task is unsupervised, and the closure copies the whole `user`. Fix: `Task.Supervisor.start_child/2` under `Accounts.TaskSupervisor` (add `{Task.Supervisor, name: Accounts.TaskSupervisor}` to the supervision tree), passing only the data the email needs.

14. **`user[:name]` on a struct raises `UndefinedFunctionError`** (structs do not implement `Access`). Fixed to dot access. The code builds the user without a `:name`, and I could not see the `User` schema, so the improved version uses `user.nickname`. Change it if `User` has a `:name` field.

15. **Pipeline into an anonymous function** (`|> (fn text -> ... end).()`) and a one-step pipeline `params["email"] |> String.downcase()`. Replaced by string interpolation and a plain call.

16. **Comments that restate code** (`# Get the role from params`, `# send the email`, `# Import a single user ...`). Deleted. The one comment that gives a reason (the provider lowercases addresses) is kept. Documentation moved to `@moduledoc`/`@doc`.

17. **Magic numbers 120 and 18** are now `@max_age` and `@min_age`.

18. **Mixed `{:error, :invalid}` for different failures** (duplicate, underage, bad input). Each now has its own reason.

19. **`Mailer` is not aliased** in the original. It is added to the alias line as `Accounts.Mailer`; adjust if it lives elsewhere.

Behavior changes to be aware of: ages above 120 are capped at 120 (as the original intended), underage returns `{:error, :underage}`, a duplicate email returns `{:error, changeset}`, and `:silent` and `:return_id` are gone. The accepted roles (`:admin`, `:editor`, `:member`) are a guess; replace them with the real set, or use `Ecto.Enum` on the schema field and drop `parse_role/1`. I did not compile or run this, because the `User`, `Repo` and `Mailer` modules are not available.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV/JSON source.
  """

  alias Accounts.{Mailer, Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from string-keyed `params`.

  `params` must hold `"email"`, `"age"` and `"role"`; `"nickname"` is optional
  and defaults to the email. Emails are lowercased because the provider
  lowercases addresses before its uniqueness check. Ages above #{@max_age} are
  capped at #{@max_age}.

  Returns `{:ok, user}`, `{:error, :invalid_params}`, `{:error, :underage}`,
  `{:error, {:invalid_field, "age"}}`, `{:error, {:unknown_role, role}}`, or
  `{:error, changeset}` when validation fails or the email is taken.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ [])

  def import_user(%{"email" => email, "age" => age, "role" => role} = params, opts)
      when is_binary(email) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, age} <- parse_age(age),
         {:ok, role} <- parse_role(role),
         {:ok, user} <- insert_user(params, age, role) do
      maybe_notify(user, opts[:notify])
      {:ok, user}
    end
  end

  def import_user(_params, _opts), do: {:error, :invalid_params}

  defp parse_age(age) when is_integer(age), do: check_age(age)

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {age, ""} ->
        check_age(age)

      {_age, _rest} ->
        {:error, {:invalid_field, "age"}}

      :error ->
        {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(_age), do: {:error, {:invalid_field, "age"}}

  defp check_age(age) when age >= @min_age, do: {:ok, min(age, @max_age)}
  defp check_age(_age), do: {:error, :underage}

  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("editor"), do: {:ok, :editor}
  defp parse_role("member"), do: {:ok, :member}
  defp parse_role(other), do: {:error, {:unknown_role, other}}

  defp insert_user(%{"email" => email} = params, age, role) do
    email = String.downcase(email)

    attrs = %{
      email: email,
      age: age,
      role: role,
      nickname: params["nickname"] || email
    }

    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp maybe_notify(user, true) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp maybe_notify(_user, false), do: :ok

  defp welcome_email(user) do
    name = user.nickname || "there"
    "Hi #{name}, welcome! Enjoy your account."
  end
end
```

`User.changeset/2`, which the importer now relies on (add to `Accounts.User`, with a unique index on `email` in a migration):

```elixir
def changeset(user, attrs) do
  user
  |> cast(attrs, [:email, :age, :role, :nickname])
  |> validate_required([:email, :age, :role])
  |> validate_number(:age, greater_than_or_equal_to: 18)
  |> unique_constraint(:email)
end
```

`welcome_email/1` now builds the message before the task starts, so the task closure copies only the finished email, not the whole `user`.
