defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from string-keyed params (CSV/JSON rows).
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from string-keyed `params`.

  Requires the `"email"`, `"age"`, and `"role"` keys. Ages above 120 are
  clamped to 120.

  Returns `{:ok, user}`, `{:error, {:missing_field, key}}`,
  `{:error, {:invalid_field, key}}`, or `{:error, changeset}` when the insert fails.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, email} <- string_field(params, "email"),
         {:ok, age} <- parse_age(params),
         {:ok, role} <- parse_role(params),
         {:ok, user} <- insert_user(email, age, role, params["nickname"]) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  defp string_field(params, key) do
    case params do
      %{^key => value} when is_binary(value) -> {:ok, value}
      %{^key => _value} -> {:error, {:invalid_field, key}}
      %{} -> {:error, {:missing_field, key}}
    end
  end

  defp parse_age(params) do
    with {:ok, text} <- string_field(params, "age"),
         {:ok, age} <- parse_integer(text) do
      validate_age(age)
    end
  end

  defp parse_integer(text) do
    case Integer.parse(text) do
      {age, ""} -> {:ok, age}
      {_age, _rest} -> {:error, {:invalid_field, "age"}}
      :error -> {:error, {:invalid_field, "age"}}
    end
  end

  defp validate_age(age) when age >= @min_age, do: {:ok, min(age, @max_age)}
  defp validate_age(_age), do: {:error, {:invalid_field, "age"}}

  defp parse_role(params) do
    with {:ok, text} <- string_field(params, "role"),
         {:ok, role} <- role_atom(text) do
      {:ok, role}
    end
  end

  defp role_atom("admin"), do: {:ok, :admin}
  defp role_atom("editor"), do: {:ok, :editor}
  defp role_atom("member"), do: {:ok, :member}
  defp role_atom(_other), do: {:error, {:invalid_field, "role"}}

  defp insert_user(email, age, role, nickname) do
    # The provider lowercases addresses before its uniqueness check, so match it here
    email = String.downcase(email)
    user = %User{email: email, age: age, role: role, nickname: nickname || email}

    case Repo.insert(user) do
      {:ok, user} -> {:ok, user}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp send_welcome(user) do
    email = welcome_email(user.nickname)

    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn ->
      Mailer.deliver(email)
    end)
  end

  defp welcome_email(nickname) do
    "Hi " <> nickname <> ", welcome! Enjoy your account."
  end
end
