defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV (comma-separated values) or JSON (JavaScript Object Notation) source.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from string-keyed params.

  Returns `{:ok, user}`, or `{:error, reason}` where `reason` is a changeset
  or a `{:missing_field, key}` or `{:invalid_field, key}` tuple. Ages above 120
  are stored as 120. Ages below 18 are rejected.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, notify: false)

    with {:ok, attrs} <- build_attrs(params),
         {:ok, user} <- insert_user(attrs) do
      if opts[:notify], do: send_welcome(user)
      {:ok, user}
    end
  end

  defp build_attrs(params) do
    with {:ok, email} <- fetch_string(params, "email"),
         {:ok, age} <- parse_age(params["age"]) do
      # The provider lowercases addresses before its uniqueness check, so match it here
      email = String.downcase(email)

      attrs = %{
        email: email,
        age: min(age, @max_age),
        role: params["role"],
        nickname: params["nickname"] || email
      }

      {:ok, attrs}
    end
  end

  defp insert_user(attrs), do: Repo.insert(User.changeset(%User{}, attrs))

  defp fetch_string(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_field, key}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp parse_age(value) when is_binary(value) do
    case Integer.parse(value) do
      {age, ""} when age >= @min_age -> {:ok, age}
      {_age, _rest} -> {:error, {:invalid_field, "age"}}
      :error -> {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(_value), do: {:error, {:invalid_field, "age"}}

  defp send_welcome(user) do
    message = welcome_message(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(message) end)
  end

  defp welcome_message(user), do: "Hi #{user.nickname}, welcome! Enjoy your account."
end
