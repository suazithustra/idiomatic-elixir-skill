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
