defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.

  The source hands over string-keyed maps. `import_user/2` validates one map
  through `Accounts.User.changeset/2`, applies the import rules the provider
  needs, inserts the user, and optionally sends a welcome email.
  """

  import Ecto.Changeset

  alias Accounts.Mailer
  alias Accounts.Repo
  alias Accounts.User

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from a string-keyed map of params.

  Returns `{:ok, user}` on success and `{:error, changeset}` when a field is
  missing or invalid, the age is under #{@min_age}, or the email is taken.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    case Repo.insert(import_changeset(params)) do
      {:ok, user} ->
        if opts[:notify], do: send_welcome(user)
        {:ok, user}

      {:error, _changeset} = error ->
        error
    end
  end

  defp import_changeset(params) do
    %User{}
    |> User.changeset(params)
    |> downcase_email()
    |> clamp_age()
    |> validate_number(:age, greater_than_or_equal_to: @min_age)
    |> put_default_nickname()
  end

  # The provider lowercases addresses before its uniqueness check, so match it here.
  defp downcase_email(changeset), do: update_change(changeset, :email, &String.downcase/1)

  defp clamp_age(changeset), do: update_change(changeset, :age, &min(&1, @max_age))

  defp put_default_nickname(changeset) do
    nickname = get_field(changeset, :nickname) || get_field(changeset, :email)
    put_change(changeset, :nickname, nickname)
  end

  defp send_welcome(user) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user), do: "Hi #{user.nickname}, welcome! Enjoy your account."
end
