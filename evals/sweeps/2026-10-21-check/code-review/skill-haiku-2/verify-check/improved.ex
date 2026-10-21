defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV (comma-separated values) or JSON source.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports a single user from the given params.

  Returns `{:ok, user}` or `{:error, reason}`.

  ## Options

    * `:notify` - sends a welcome email after the insert. Defaults to `false`.
  """
  def import_user(params, opts \\ []) do
    [notify: notify] = Keyword.validate!(opts, notify: false)

    with {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         :ok <- check_adult(age),
         {:ok, user} <- insert_user(params, email, age) do
      if notify, do: send_welcome(user)
      {:ok, user}
    end
  end

  @doc """
  Imports a single user and returns its ID.

  Takes the same options as `import_user/2`.
  """
  def import_user_id(params, opts \\ []) do
    case import_user(params, opts) do
      {:ok, user} -> {:ok, user.id}
      {:error, _reason} = error -> error
    end
  end

  defp parse_email(nil), do: {:error, {:missing_field, "email"}}
  defp parse_email(email) when is_binary(email), do: {:ok, String.downcase(email)}
  defp parse_email(_email), do: {:error, {:invalid_field, "email"}}

  defp parse_age(nil), do: {:error, {:missing_field, "age"}}

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {value, ""} -> {:ok, min(value, @max_age)}
      _ -> {:error, {:invalid_field, "age"}}
    end
  end

  defp parse_age(_age), do: {:error, {:invalid_field, "age"}}

  defp check_adult(age) when age >= @min_age, do: :ok
  defp check_adult(_age), do: {:error, {:invalid_field, "age"}}

  defp insert_user(params, email, age) do
    attrs = %{
      "email" => email,
      "age" => age,
      "role" => params["role"],
      "nickname" => params["nickname"] || email
    }

    case Repo.insert(User.import_changeset(%User{}, attrs)) do
      {:ok, user} -> {:ok, user}
      {:error, changeset} -> {:error, {:insert_failed, changeset}}
    end
  end

  defp send_welcome(user) do
    email = welcome_email(user)
    Task.Supervisor.start_child(Accounts.TaskSupervisor, fn -> Mailer.deliver(email) end)
  end

  defp welcome_email(user) do
    name = user.name || "there"
    "Hi #{name}, welcome! Enjoy your account."
  end
end
