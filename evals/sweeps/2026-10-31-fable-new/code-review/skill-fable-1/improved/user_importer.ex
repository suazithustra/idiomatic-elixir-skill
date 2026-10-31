defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  import Ecto.Changeset, only: [get_field: 2, put_change: 3, update_change: 3]

  alias Accounts.{Repo, User}

  @doc """
  Imports a single user from the string-keyed `params` of one source row.

  Returns `{:ok, user}` or `{:error, changeset}`.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, user} <- insert_user(params) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  defp insert_user(params) do
    %User{}
    |> User.changeset(params)
    # The provider lowercases addresses before its uniqueness check, so match it here
    |> update_change(:email, &String.downcase/1)
    |> put_default_nickname()
    |> Repo.insert()
  end

  defp put_default_nickname(changeset) do
    if is_nil(get_field(changeset, :nickname)) do
      put_change(changeset, :nickname, get_field(changeset, :email))
    else
      changeset
    end
  end

  defp send_welcome(user) do
    message = welcome_message(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(message) end)
  end

  defp welcome_message(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
