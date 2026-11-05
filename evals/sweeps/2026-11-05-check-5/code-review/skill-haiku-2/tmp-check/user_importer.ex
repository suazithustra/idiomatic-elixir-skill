defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.

  Params are string-keyed maps. The field rules live in
  `Accounts.User.import_changeset/2`.
  """

  alias Accounts.{Repo, User}

  @doc """
  Imports one user from string-keyed `params`.

  Returns `{:ok, user}` or `{:error, changeset}`. The changeset's errors name
  the failing field, such as `:email` for an address already in use or `:age`
  for a user under 18.

  ## Options

    * `:notify` - `:welcome` sends a welcome email after the insert.
      Defaults to `:none`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: :none)

    with {:ok, user} <- insert_user(params) do
      maybe_send_welcome(user, opts[:notify])
      {:ok, user}
    end
  end

  defp insert_user(params) do
    %User{}
    |> User.import_changeset(params)
    |> Repo.insert()
  end

  defp maybe_send_welcome(user, :welcome), do: send_welcome(user)
  defp maybe_send_welcome(_user, :none), do: :ok

  defp send_welcome(user) do
    email = welcome_email(user)

    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn ->
      Mailer.deliver(email)
    end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
