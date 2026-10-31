# Review of `Accounts.UserImporter`

The module has two bugs that change results: the age cap never applies, and a blanket `rescue` hides every failure as `:invalid`. Several smaller patterns follow. I read `SKILL.md`, `references/processes.md` and `references/ecto-phoenix.md`.

## Findings

1. **Age cap does nothing** (rule: assign the result of `if`; rebinding inside a block does not escape it). `if age > 120 do age = 120 end` leaves `age` unchanged outside the `if`. Fix: `min(age, @max_age)`.

2. **`String.to_atom(params["role"])`** (rule: convert external strings to atoms with explicit clauses). Input can exhaust the atom table, and a missing role raises. Fix: `parse_role/1` with one clause per accepted role and `{:error, {:invalid_field, "role"}}` for anything else.

3. **`try ... rescue _ -> {:error, :invalid}`** (rule: return tuples for expected failures; never `rescue _`). It turns every bug into `:invalid`. Fix: remove it. `Integer.parse/1` replaces `String.to_integer/1`, and a function head replaces the `nil` crash in `String.downcase/1`.

4. **`%User{...}` passed to `Repo.insert/1`** (ecto-phoenix: validate with changesets). Nothing is validated, and the `_ -> {:error, :insert_failed}` clause discards the reason. Fix: `User.changeset/2` and return `{:error, changeset}`.

5. **`Repo.get_by(User, email: email) == nil` before insert** (rule: `unique_constraint/3` instead of a hand-built lookup). The lookup is a race, so two concurrent imports can both pass it. Fix: `unique_constraint(:email)` in the changeset.

6. **`_ ->` in the `case` on `Repo.insert/1`** (rule: match every expected shape). Fix: match `{:ok, user}` and `{:error, %Ecto.Changeset{}}`.

7. **`is_binary(email) && age >= 18`** (rule: `and` for booleans). The `is_binary` check also runs after `String.downcase(email)` has already raised on a non-string. Fix: check it in the function head with `when is_binary(email)`. The age check uses `and`-free clause logic in `parse_age/1`.

8. **Nested `if`/`case`/`if`** (rule: `with` plus small private functions). Fix: `with` over `parse_age/1`, `parse_role/1` and `insert_user/1`, with one error shape per step.

9. **Required params read with `params["email"]`** (rule: match required string-keyed input in the head, with a catch-all clause). Fix: head matches `"email"`, `"age"` and `"role"`, and a second clause returns `{:error, :invalid_params}`. `params["nickname"]` stays, because it is optional.

10. **Overlapping `notify` and `silent` options** (rule: one atom-valued option). `opts[:notify] && !opts[:silent]` has a meaningless `notify: true, silent: true` case. Fix: only `notify:`, checked with `Keyword.validate!/2` and documented.

11. **`return_id` changes the return shape** (rule: one return shape per function). `user.id` or `{:ok, user}` depending on an option. Fix: removed. `import_user_id/2` is a separate function for callers that want the id.

12. **Unsupervised `spawn/1` that copies the whole `user`** (processes: supervise, and send processes only what they need). A crash or shutdown is invisible. Fix: `Task.Supervisor.start_child/2` under `Accounts.TaskSupervisor` (it must be started in the application's supervision tree), passing only the email and nickname.

13. **`user[:name]` on a struct** (rule: structs do not implement `Access`). It raises `UndefinedFunctionError`. The struct built here has no `name`, so I use `nickname`. If `User` has a `name` field, use `user.name`.

14. **`greeting |> (fn ... end).()`** (rule: no pipe into an anonymous function). The three-step greeting is one string. Fix: string interpolation.

15. **Magic numbers and comments** (rules: name magic numbers; comments explain why). `18` and `120` become `@minimum_age` and `@maximum_age`. I deleted the comments that restate the code (`# Get the role from params`, `# send the email`, the header comments). I kept the one about the provider lowercasing addresses. `@moduledoc`, `@doc` and `@spec` replace the header comments.

## Assumptions

- The role values `:admin`, `:editor` and `:member` are placeholders. Replace them with the real set.
- `Mailer` is not aliased in the original. I kept it as `Accounts.Mailer`, so adjust it if it lives elsewhere.
- `User.changeset/2` (below) is new. The existing schema is not shown, so check it against the real fields.

## Improved code

```elixir
defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV/JSON source.
  """

  alias Accounts.Mailer
  alias Accounts.Repo
  alias Accounts.User

  @minimum_age 18
  @maximum_age 120

  @doc """
  Imports a single user from string-keyed params.

  Requires `"email"`, `"age"` and `"role"`; `"nickname"` is optional and
  defaults to the email. Ages above #{@maximum_age} are capped.

  Returns `{:ok, user}`, `{:error, :invalid_params}` when a required key is
  missing, `{:error, {:invalid_field, key}}` for a bad age or role, or
  `{:error, changeset}` when the insert fails, including a duplicate email.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  @spec import_user(map(), keyword()) ::
          {:ok, User.t()}
          | {:error, :invalid_params | {:invalid_field, String.t()} | Ecto.Changeset.t()}
  def import_user(params, opts \\ [])

  def import_user(%{"email" => email, "age" => age, "role" => role} = params, opts)
      when is_binary(email) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, age} <- parse_age(age),
         {:ok, role} <- parse_role(role),
         attrs = build_attrs(params, email, age, role),
         {:ok, user} <- insert_user(attrs) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  def import_user(_params, _opts), do: {:error, :invalid_params}

  @doc """
  Like `import_user/2`, but returns `{:ok, id}` instead of `{:ok, user}`.
  """
  @spec import_user_id(map(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def import_user_id(params, opts \\ []) do
    with {:ok, user} <- import_user(params, opts) do
      {:ok, user.id}
    end
  end

  defp build_attrs(params, email, age, role) do
    # The provider lowercases addresses before its uniqueness check, so match it here
    email = String.downcase(email)

    %{
      email: email,
      age: age,
      role: role,
      nickname: params["nickname"] || email
    }
  end

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {age, ""} when age >= @minimum_age ->
        {:ok, min(age, @maximum_age)}

      _invalid ->
        {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(_age), do: {:error, {:invalid_field, "age"}}

  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("editor"), do: {:ok, :editor}
  defp parse_role("member"), do: {:ok, :member}
  defp parse_role(_role), do: {:error, {:invalid_field, "role"}}

  defp insert_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp send_welcome(user) do
    email = user.email
    nickname = user.nickname

    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn ->
      Mailer.deliver(welcome_email(email, nickname))
    end)
  end

  defp welcome_email(email, nickname) do
    %{to: email, body: "Hi #{nickname}, welcome! Enjoy your account."}
  end
end
```

Matching `User.changeset/2` (in `Accounts.User`; `unique_constraint/2` needs a unique index on `email`):

```elixir
def changeset(user, attrs) do
  user
  |> cast(attrs, [:email, :age, :role, :nickname])
  |> validate_required([:email, :age, :role])
  |> unique_constraint(:email)
end
```

Notes on the improved code:

- `welcome_email/2` now returns a map rather than whatever `Mailer.deliver/1` expected before, because the original body was not shown. Adjust it to the real email type.
- I did not run `mix format` or the compiler because there is no Mix project here with `Accounts.User`, `Repo` or `Mailer`.
