defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV (comma-separated values) or JSON (JavaScript Object Notation) source.
  """

  alias Accounts.{Repo, User}

  @max_age 120

  @doc """
  Imports a single user from string-keyed params.

  Returns `{:ok, user}` or `{:error, reason}`.

  ## Options

    * `:welcome_email` - `:send` sends a welcome email after the insert,
      `:skip` sends none. Defaults to `:skip`.
  """
  def import_user(params, opts \\ []) do
    opts = Keyword.validate!(opts, welcome_email: :skip)

    with {:ok, attrs} <- parse_params(params),
         {:ok, user} <- insert_user(attrs) do
      if opts[:welcome_email] == :send, do: send_welcome(user)
      {:ok, user}
    end
  end

  @doc """
  Same as `import_user/2`, but returns `{:ok, id}` instead of `{:ok, user}`.
  """
  def import_user_id(params, opts \\ []) do
    with {:ok, user} <- import_user(params, opts), do: {:ok, user.id}
  end

  defp parse_params(params) do
    with {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         {:ok, role} <- parse_role(params["role"]) do
      {:ok,
       %{
         email: email,
         age: age,
         role: role,
         nickname: params["nickname"] || email
       }}
    end
  end

  # The provider lowercases addresses before its uniqueness check, so match it here
  defp parse_email(email) when is_binary(email), do: {:ok, String.downcase(email)}
  defp parse_email(nil), do: {:error, {:missing_field, "email"}}
  defp parse_email(_email), do: {:error, {:invalid_field, "email"}}

  defp parse_age(nil), do: {:error, {:missing_field, "age"}}

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {value, ""} -> {:ok, min(value, @max_age)}
      _ -> {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(_age), do: {:error, {:invalid_field, "age"}}

  defp parse_role("admin"), do: {:ok, :admin}
  defp parse_role("editor"), do: {:ok, :editor}
  defp parse_role("viewer"), do: {:ok, :viewer}
  defp parse_role(_role), do: {:error, {:invalid_field, "role"}}

  defp insert_user(attrs) do
    changeset = User.changeset(%User{}, attrs)

    case Repo.insert(changeset) do
      {:ok, user} -> {:ok, user}
      {:error, changeset} -> {:error, {:invalid_user, changeset}}
    end
  end

  defp send_welcome(user) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
