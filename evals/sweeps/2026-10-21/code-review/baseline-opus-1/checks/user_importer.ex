defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from rows parsed out of an external CSV or JSON source.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  # Roles an external file is allowed to grant. Replace with the real list and
  # keep privileged roles out of it.
  @importable_roles %{"member" => :member, "viewer" => :viewer}

  @type error_reason ::
          :invalid_email | :invalid_age | :underage | :invalid_role | Ecto.Changeset.t()

  @doc """
  Validates a row of string-keyed `params` and inserts the user.

  ## Options

    * `:notify` - send a welcome email after a successful insert. Defaults to `false`.
  """
  @spec import_user(map(), keyword()) :: {:ok, %User{}} | {:error, error_reason()}
  def import_user(params, opts \\ []) do
    with {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         {:ok, role} <- parse_role(params["role"]),
         nickname = nickname(params["nickname"], email),
         {:ok, user} <- insert(%{email: email, age: age, role: role, nickname: nickname}) do
      if Keyword.get(opts, :notify, false), do: send_welcome(user)
      {:ok, user}
    end
  end

  # The provider lowercases addresses before its uniqueness check, so match it here.
  defp parse_email(email) when is_binary(email) do
    email = email |> String.trim() |> String.downcase()
    if String.contains?(email, "@"), do: {:ok, email}, else: {:error, :invalid_email}
  end

  defp parse_email(_email), do: {:error, :invalid_email}

  # JSON sources give integers, CSV sources give strings.
  defp parse_age(age) when is_integer(age), do: check_age(age)

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(String.trim(age)) do
      {age, ""} -> check_age(age)
      _ -> {:error, :invalid_age}
    end
  end

  defp parse_age(_age), do: {:error, :invalid_age}

  defp check_age(age) when age < 0, do: {:error, :invalid_age}
  defp check_age(age) when age < @min_age, do: {:error, :underage}
  defp check_age(age), do: {:ok, min(age, @max_age)}

  defp parse_role(role) do
    case Map.fetch(@importable_roles, role) do
      {:ok, role} -> {:ok, role}
      :error -> {:error, :invalid_role}
    end
  end

  # CSV rows carry empty strings for missing columns.
  defp nickname(nickname, email) when is_binary(nickname) do
    case String.trim(nickname) do
      "" -> email
      nickname -> nickname
    end
  end

  defp nickname(_nickname, email), do: email

  defp insert(attrs) do
    %User{}
    |> Ecto.Changeset.change(attrs)
    |> Ecto.Changeset.unique_constraint(:email)
    |> Repo.insert()
  end

  defp send_welcome(user) do
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn ->
      user |> welcome_email() |> Mailer.deliver()
    end)
  end

  defp welcome_email(%User{nickname: nickname}) do
    "Hi #{nickname}, welcome! Enjoy your account."
  end
end
