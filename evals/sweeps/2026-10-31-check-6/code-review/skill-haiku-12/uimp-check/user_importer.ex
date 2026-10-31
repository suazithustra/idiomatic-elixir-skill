defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from string-keyed params.
  """
  def import_user(params, opts \\ []) do
    with {:ok, attrs} <- parse_params(params),
         {:ok, user} <- insert_user(attrs) do
      maybe_notify(user, opts[:notify])
      {:ok, user}
    end
  end

  @doc """
  Imports a user as `import_user/2` does, and returns `{:ok, id}`.
  """
  def import_user_id(params, opts \\ []) do
    with {:ok, user} <- import_user(params, opts), do: {:ok, user.id}
  end

  defp parse_params(%{"email" => email, "age" => age, "role" => role} = params)
       when is_binary(email) do
    # The provider lowercases addresses before its uniqueness check, so match it here
    email = String.downcase(email)

    with {:ok, age} <- parse_age(age),
         {:ok, role} <- parse_role(role) do
      attrs = %{
        email: email,
        age: min(age, @max_age),
        role: role,
        nickname: params["nickname"] || email
      }

      {:ok, attrs}
    end
  end

  defp parse_params(_params), do: {:error, :invalid_params}

  defp parse_age(text) when is_binary(text) do
    case Integer.parse(text) do
      {age, ""} when age >= @min_age -> {:ok, age}
      _ -> {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(_text), do: {:error, {:invalid_field, "age"}}

  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("editor"), do: {:ok, :editor}
  defp parse_role("member"), do: {:ok, :member}
  defp parse_role(other), do: {:error, {:unknown_role, other}}

  defp insert_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp maybe_notify(user, :welcome), do: send_welcome(user)
  defp maybe_notify(_user, _notify), do: :ok

  defp send_welcome(user) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user), do: "Hi #{user.name || "there"}, welcome! Enjoy your account."
end
