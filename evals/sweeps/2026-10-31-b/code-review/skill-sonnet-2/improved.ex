defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV/JSON source.
  """

  alias Accounts.{Repo, User}

  @max_age 120

  @doc """
  Imports a single user from string-keyed `params`.

  `params` must hold `"email"`, `"age"` and `"role"` as strings; `"nickname"`
  is optional and defaults to the email. An age above #{@max_age} is stored as
  #{@max_age}. Returns `{:error, %Ecto.Changeset{}}` when validation fails or
  the email is already taken.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  @spec import_user(map(), keyword()) :: {:ok, User.t()} | {:error, term()}
  def import_user(params, opts \\ [])

  def import_user(%{"email" => email, "age" => age, "role" => role} = params, opts)
      when is_binary(email) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, role} <- parse_role(role),
         {:ok, age} <- parse_age(age),
         {:ok, user} <- insert_user(params, role, age) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  def import_user(_params, _opts), do: {:error, :invalid_params}

  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("editor"), do: {:ok, :editor}
  defp parse_role("member"), do: {:ok, :member}
  defp parse_role(other), do: {:error, {:unknown_role, other}}

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {age, ""} ->
        {:ok, min(age, @max_age)}

      {_age, _rest} ->
        {:error, {:invalid_field, "age"}}

      :error ->
        {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(_age), do: {:error, {:invalid_field, "age"}}

  defp insert_user(%{"email" => email} = params, role, age) do
    # The provider lowercases addresses before its uniqueness check, so match it here
    email = String.downcase(email)
    attrs = %{email: email, age: age, role: role, nickname: params["nickname"] || email}

    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
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
