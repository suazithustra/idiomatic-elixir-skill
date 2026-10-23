# Review: `Accounts.UserImporter`

## Findings

### Bugs
1. **`age = 120` inside `if` has no effect.** Elixir rebinding doesn't leak out of the `if` block (compiler warns "unused variable"). Ages over 120 are never capped. Use `min(age, 120)`.
2. **`String.to_atom(params["role"])` on external input** leaks atoms (the atom table is never GC'd, so this is a DoS vector). It also raises on `nil`, and it sits *outside* the `try`, so a missing role crashes while other bad input returns `{:error, :invalid}`. Use an explicit allow-list.
3. **`user[:name]` on a `%User{}` struct raises.** Structs don't implement `Access`. The `User` struct is also built with `:email`, not `:name`, so the field may not exist. Use pattern matching or `Map.get`/`user.nickname`.
4. **`is_binary(email)` is checked after `String.downcase(email)`.** The guard is dead code, because `downcase(nil)` has already raised. Validate before transforming.
5. **`nickname = params["nickname"] || email`** is fine, but an empty string `""` is kept as a nickname. Treat blank as missing.
6. **`Mailer` is never aliased or defined here.** Check the module name. `welcome_email/1` returns a plain string, not an email struct, so `Mailer.deliver/1` will likely fail, and does so silently inside the spawned process.

### Design / idiom
7. **Blanket `try/rescue _ ->`** hides real bugs (DB errors, typos, the struct `Access` error above) behind `{:error, :invalid}`. Parse and validate explicitly with `with`, and let unexpected errors crash.
8. **Inconsistent return type.** `opts[:return_id]` makes the function return either `{:ok, user}` or a bare id. Callers can't pattern match reliably. Always return `{:ok, user}`; the caller can take `.id`.
9. **`Repo.insert(%User{})` bypasses changeset validation and constraints** (such as the unique email the comment mentions), and `_ -> {:error, :insert_failed}` throws away the changeset errors. Use `User.changeset/2` (assumed to exist) and return `{:error, changeset}`.
10. **`String.to_integer` raises** on bad or missing input. Use `Integer.parse/1` and require a full parse.
11. **Unsupervised `spawn`** loses failures and can't be tracked. Use `Task.Supervisor.start_child/2` (assumes an `Accounts.TaskSupervisor` in the supervision tree).
12. **`opts[:notify] && !opts[:silent]`** is confusing. Use `Keyword.get/3` and `and`/`not` on booleans. Better still, drop one of the two flags if they are redundant.
13. **`greeting |> (fn ... end).()`** is pointless. Use string interpolation.
14. **Noise comments** ("Get the role from params", "send the email") restate the code. Replace them with `@moduledoc`/`@doc`. Keep the useful comment about the provider lowercasing.
15. **Naming:** the `import_user` options are undocumented. Add `@spec`s.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV/JSON source.
  """

  alias Accounts.{Mailer, Repo, User}

  @roles %{"admin" => :admin, "member" => :member, "guest" => :guest}
  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from string-keyed `params`.

  ## Options

    * `:notify` - send a welcome email after insert (default `false`)

  Returns `{:ok, user}`, `{:error, :invalid}` for unparseable or ineligible
  input, or `{:error, changeset}` if the insert fails.
  """
  @spec import_user(map(), keyword()) ::
          {:ok, User.t()} | {:error, :invalid | Ecto.Changeset.t()}
  def import_user(params, opts \\ []) do
    with {:ok, email} <- fetch_email(params),
         {:ok, age} <- fetch_age(params),
         {:ok, role} <- fetch_role(params),
         {:ok, user} <- insert(email, age, role, params["nickname"]) do
      if Keyword.get(opts, :notify, false), do: send_welcome(user)
      {:ok, user}
    end
  end

  defp insert(email, age, role, nickname) do
    attrs = %{email: email, age: age, role: role, nickname: blank_to(nickname, email)}

    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  # The provider lowercases addresses before its uniqueness check, so match it here
  defp fetch_email(%{"email" => email}) when is_binary(email), do: {:ok, String.downcase(email)}
  defp fetch_email(_params), do: {:error, :invalid}

  defp fetch_age(%{"age" => age}) when is_binary(age) do
    case Integer.parse(age) do
      {age, ""} when age >= @min_age -> {:ok, min(age, @max_age)}
      _ -> {:error, :invalid}
    end
  end

  defp fetch_age(_params), do: {:error, :invalid}

  defp fetch_role(%{"role" => role}) do
    case Map.fetch(@roles, role) do
      {:ok, _role} = ok -> ok
      :error -> {:error, :invalid}
    end
  end

  defp fetch_role(_params), do: {:error, :invalid}

  defp blank_to(value, default) when value in [nil, ""], do: default
  defp blank_to(value, _default), do: value

  defp send_welcome(user) do
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn ->
      user |> welcome_email() |> Mailer.deliver()
    end)
  end

  defp welcome_email(%User{nickname: nickname}) do
    "Hi #{nickname}, welcome! Enjoy your account."
  end
end
```

Assumptions: `User.changeset/2`, `User.t()`, `Accounts.Mailer` and `Accounts.TaskSupervisor` exist or must be added. `welcome_email/1` still returns a string, so build a real email struct if your mailer needs one. The `:silent` and `:return_id` options were removed; update any callers.
