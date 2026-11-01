defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.{Repo, User}

  @doc """
  Imports a single user from string-keyed params.

  Returns `{:ok, user}` on success and `{:error, changeset}` when the params
  are invalid or the email is already taken.

  ## Options

    * `:notify` - `:welcome` sends a welcome email after the insert.
      `:silent` (the default) sends nothing.
  """
  def import_user(params, opts \\ []) do
    changeset = User.changeset(%User{}, params)

    with {:ok, user} <- Repo.insert(changeset) do
      maybe_send_welcome(user, opts[:notify])
      {:ok, user}
    end
  end

  defp maybe_send_welcome(user, :welcome), do: send_welcome(user)
  defp maybe_send_welcome(_user, _silent), do: :ok

  defp send_welcome(user) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
