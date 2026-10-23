# Review: Accounts.UserImporter

## Findings

1. **Bug: `age = 120` inside `if` has no effect.** Elixir rebinding doesn't leak out of `if`, so ages above 120 are never capped (compiler warns "unused variable"). Use `min(age, 120)`.
2. **Security: `String.to_atom/1` on external input.** Atoms are never garbage-collected, so arbitrary roles can exhaust the atom table and crash the VM. It also raises on `nil`, outside the `try`. Map known role strings to atoms explicitly.
3. **`try/rescue` used as control flow.** `_ -> {:error, :invalid}` hides every failure: missing keys (`nil` into `String.downcase`), bad integers, and real bugs such as a `Repo.insert` exception or a typo. Use `with` and `Integer.parse/1` and return tagged errors.
4. **Dead/incorrect validation.** `is_binary(email)` runs after `String.downcase(email)`, which already raised for non-binaries. Check before use. Email isn't checked for blank or malformed either.
5. **`nickname` fallback.** `params["nickname"] || email` accepts `""` as a valid nickname. Treat blank as missing.
6. **Insert errors are discarded.** `_ -> {:error, :insert_failed}` throws away the changeset. Return `{:error, changeset}`. Inserting a bare struct also skips validations and constraints. Go through `User.changeset/2` (assumed to exist) so a unique-email violation is returned, not raised.
7. **Inconsistent return type.** The `:return_id` option makes the function return either a bare id or `{:ok, user}`. This breaks the `{:ok, _} | {:error, _}` convention and makes callers branch. Callers can take `user.id` themselves. Removed.
8. **`user[:name]` on a struct.** Structs don't implement `Access`, so this raises `UndefinedFunctionError` at runtime (and `:name` may not be a field at all). Use `user.name` or a pattern match.
9. **Unsupervised `spawn`.** A crashing mail delivery is silent and untracked, and it can be lost on shutdown. Use `Task.Supervisor.start_child/2`. `Mailer` is also unaliased.
10. **Needless complexity.** `greeting |> (fn ... end).()` is just string concatenation. `opts[:notify] && !opts[:silent]` is clearer as `Keyword.get`. Use `&&`/`!` only when truthiness is intended; here `and`/`not` on booleans are cleaner.
11. **Comments.** Most restate the code ("Get the role from params", "send the email"). Removed. The one useful comment (provider lowercases emails) is kept. Add `@moduledoc`/`@doc`/`@spec`.

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

  @type error :: :invalid | Ecto.Changeset.t()

  @doc """
  Imports a single user from string-keyed `params`.

  Options:

    * `:notify` - send a welcome email after insert (default `false`)
    * `:silent` - suppresses the welcome email even if `:notify` is set
  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, error()}
  def import_user(params, opts \\ []) do
    with {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         {:ok, role} <- parse_role(params["role"]),
         {:ok, user} <- insert(email, age, role, params["nickname"]) do
      if Keyword.get(opts, :notify, false) and not Keyword.get(opts, :silent, false) do
        send_welcome(user)
      end

      {:ok, user}
    end
  end

  defp insert(email, age, role, nickname) do
    attrs = %{email: email, age: age, role: role, nickname: blank_to_nil(nickname) || email}

    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  # The provider lowercases addresses before its uniqueness check, so match it here
  defp parse_email(email) when is_binary(email) do
    case email |> String.trim() |> String.downcase() do
      "" -> {:error, :invalid}
      email -> {:ok, email}
    end
  end

  defp parse_email(_), do: {:error, :invalid}

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {age, ""} when age >= @min_age -> {:ok, min(age, @max_age)}
      _ -> {:error, :invalid}
    end
  end

  defp parse_age(_), do: {:error, :invalid}

  defp parse_role(role) do
    case Map.fetch(@roles, role) do
      {:ok, _} = ok -> ok
      :error -> {:error, :invalid}
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(_), do: nil

  defp send_welcome(user) do
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn ->
      Mailer.deliver(welcome_email(user))
    end)
  end

  defp welcome_email(%User{} = user) do
    name = user.name || "there"
    "Hi " <> name <> ", welcome! Enjoy your account."
  end
end
```

Assumptions: `User.changeset/2` exists and casts these fields, `Accounts.TaskSupervisor` is started in the application tree, and `Mailer` lives under `Accounts` (adjust the alias if not). The `:return_id` option was removed deliberately; callers use `{:ok, user}` and read `user.id`.
