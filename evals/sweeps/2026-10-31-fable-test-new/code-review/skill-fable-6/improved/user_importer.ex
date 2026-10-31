defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.{Repo, User}

  @doc """
  Imports a single user from string-keyed `params`.

  Returns `{:ok, user}` or `{:error, changeset}`.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, user} <- Repo.insert(User.import_changeset(%User{}, params)) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  defp send_welcome(user) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user), do: "Hi #{user.nickname}, welcome! Enjoy your account."
end
