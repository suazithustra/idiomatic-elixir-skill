defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  # Roles accepted from the import file. Replace with the real role list.
  @roles %{"admin" => :admin, "member" => :member}

  @doc """
  Inserts a user built from `params`.

  Returns `{:ok, user}` on success, `{:error, :invalid}` when a field fails
  validation, or `{:error, :insert_failed}` when the insert is rejected.

  Options:

    * `:notify` - send a welcome email (default: `false`)
    * `:silent` - suppress the welcome email even when `:notify` is set
    * `:return_id` - return the new user's id instead of `{:ok, user}`
  """
  def import_user(params, opts \\ []) do
    with {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         {:ok, role} <- parse_role(params["role"]) do
      user = %User{
        email: email,
        age: age,
        role: role,
        nickname: params["nickname"] || email
      }

      insert_user(user, opts)
    end
  end

  defp parse_email(email) when is_binary(email), do: {:ok, String.downcase(email)}
  defp parse_email(_), do: {:error, :invalid}

  # Accepts integers (JSON) and numeric strings (CSV). Ages above the maximum
  # are reduced to it; ages below the minimum are rejected.
  defp parse_age(age) when is_integer(age), do: check_age(age)

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {value, ""} -> check_age(value)
      _ -> {:error, :invalid}
    end
  end

  defp parse_age(_), do: {:error, :invalid}

  defp check_age(age) when age >= @min_age, do: {:ok, min(age, @max_age)}
  defp check_age(_), do: {:error, :invalid}

  defp parse_role(role) do
    case Map.fetch(@roles, role) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, :invalid}
    end
  end

  defp insert_user(user, opts) do
    case Repo.insert(user) do
      {:ok, user} ->
        if opts[:notify] && !opts[:silent], do: send_welcome(user)

        if opts[:return_id], do: user.id, else: {:ok, user}

      {:error, _changeset} ->
        {:error, :insert_failed}
    end
  end

  defp send_welcome(user) do
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn ->
      Mailer.deliver(welcome_email(user))
    end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
