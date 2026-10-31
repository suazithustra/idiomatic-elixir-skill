defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external source, such as a CSV (comma-separated values)
  or JSON (JavaScript Object Notation) feed.
  """

  alias Accounts.{Repo, User}

  @max_age 120
  @min_age 18

  @doc """
  Imports a single user from string-keyed params.

  Returns `{:ok, user}` when the user is inserted. Otherwise returns one of:

    * `{:error, {:invalid_field, key}}` when a field is missing or malformed
    * `{:error, :email_taken}` when another user already has the email
    * `{:error, changeset}` when the database rejects the insert

  ## Options

    * `:notify` - `:welcome` sends a welcome email after the insert, `:none`
      sends nothing. Defaults to `:none`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: :none)

    with {:ok, attrs} <- parse_params(params),
         {:ok, user} <- insert_user(attrs) do
      maybe_send_welcome(user, opts[:notify])
      {:ok, user}
    end
  end

  defp parse_params(params) do
    with {:ok, email} <- email_field(params),
         {:ok, age} <- age_field(params),
         {:ok, role} <- role_field(params) do
      attrs = %{email: email, age: age, role: role, nickname: params["nickname"] || email}
      {:ok, attrs}
    end
  end

  # The provider lowercases addresses before its uniqueness check, so match it here
  defp email_field(%{"email" => email}) when is_binary(email) do
    {:ok, String.downcase(email)}
  end

  defp email_field(_params), do: {:error, {:invalid_field, "email"}}

  defp age_field(%{"age" => age}) when is_binary(age) do
    case Integer.parse(age) do
      {value, ""} when value >= @min_age -> {:ok, min(value, @max_age)}
      _ -> {:error, {:invalid_field, "age"}}
    end
  end

  defp age_field(_params), do: {:error, {:invalid_field, "age"}}

  # Replace these with the roles the app defines. Input is never converted with
  # String.to_atom/1, because each unknown string would create an atom that is never freed.
  defp role_field(%{"role" => "admin"}), do: {:ok, :admin}
  defp role_field(%{"role" => "editor"}), do: {:ok, :editor}
  defp role_field(%{"role" => "member"}), do: {:ok, :member}
  defp role_field(_params), do: {:error, {:invalid_field, "role"}}

  defp insert_user(attrs) do
    case Repo.insert(User.changeset(%User{}, attrs)) do
      {:ok, user} ->
        {:ok, user}

      {:error, changeset} ->
        {:error, insert_reason(changeset)}
    end
  end

  defp insert_reason(%Ecto.Changeset{errors: [email: {_message, opts}]} = changeset) do
    case Keyword.get(opts, :constraint) do
      :unique -> :email_taken
      _ -> changeset
    end
  end

  defp insert_reason(changeset), do: changeset

  defp maybe_send_welcome(user, :welcome) do
    message = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(message) end)
  end

  defp maybe_send_welcome(_user, :none), do: :ok

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
