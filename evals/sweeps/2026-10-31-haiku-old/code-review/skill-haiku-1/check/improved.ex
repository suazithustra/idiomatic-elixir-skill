defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from external CSV (comma-separated values) and JSON
  (JavaScript Object Notation) sources.
  """

  alias Accounts.{Repo, User}

  @max_age 120
  @min_age 18

  @doc """
  Imports one user from string-keyed params.

  Returns `{:ok, user}`, or `{:error, reason}` where `reason` is
  `{:missing_field, key}`, `{:invalid_field, key}`, or a changeset when
  the database rejects the row.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, attrs} <- parse_params(params),
         {:ok, user} <- insert_user(attrs) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  defp parse_params(params) do
    with {:ok, email} <- string_field(params, "email"),
         {:ok, age} <- age_field(params),
         {:ok, role} <- role_field(params) do
      # The provider lowercases addresses before its uniqueness check, so match it here
      email = String.downcase(email)

      attrs = %{
        email: email,
        age: min(age, @max_age),
        role: role,
        nickname: params["nickname"] || email
      }

      {:ok, attrs}
    end
  end

  defp string_field(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp age_field(params) do
    case string_field(params, "age") do
      {:ok, text} -> parse_age(text)
      {:error, _reason} = error -> error
    end
  end

  defp parse_age(text) do
    case Integer.parse(text) do
      {age, ""} when age >= @min_age -> {:ok, age}
      _ -> {:error, {:invalid_field, "age"}}
    end
  end

  # Placeholder roles: replace with the roles the application defines
  defp role_field(params) do
    case string_field(params, "role") do
      {:ok, "admin"} -> {:ok, :admin}
      {:ok, "editor"} -> {:ok, :editor}
      {:ok, "viewer"} -> {:ok, :viewer}
      {:ok, _other} -> {:error, {:invalid_field, "role"}}
      {:error, _reason} = error -> error
    end
  end

  defp insert_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  defp send_welcome(user) do
    message = welcome_text(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(message) end)
  end

  defp welcome_text(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
