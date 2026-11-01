defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from external CSV (comma-separated values) and JSON (JavaScript Object Notation) sources.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from string-keyed `params`.

  Returns `{:ok, user}` on success. Returns `{:error, {:missing_field, key}}` or
  `{:error, {:invalid_field, key}}` for a bad input field, `{:error, :underage}` for an
  age below 18, and `{:error, changeset}` when the database rejects the user, such as on
  a duplicate email. Ages above 120 are stored as 120.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, attrs} <- parse_attrs(params),
         {:ok, user} <- insert_user(attrs) do
      if opts[:notify], do: send_welcome(user)

      {:ok, user}
    end
  end

  defp parse_attrs(params) do
    with {:ok, raw_email} <- string_field(params, "email"),
         {:ok, age_text} <- string_field(params, "age"),
         {:ok, age} <- parse_integer(age_text, "age"),
         {:ok, role} <- string_field(params, "role"),
         :ok <- check_adult(age) do
      # The provider lowercases addresses before its uniqueness check, so match it here
      email = String.downcase(raw_email)

      attrs = %{
        email: email,
        age: min(age, @max_age),
        role: role,
        nickname: params["nickname"] || email
      }

      {:ok, attrs}
    end
  end

  defp insert_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp string_field(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp parse_integer(text, key) do
    case Integer.parse(text) do
      {integer, ""} -> {:ok, integer}
      {_integer, _rest} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:invalid_field, key}}
    end
  end

  defp check_adult(age) when age >= @min_age, do: :ok
  defp check_adult(_age), do: {:error, :underage}

  defp send_welcome(user) do
    message = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(message) end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
