defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV/JSON source.

  Returns `{:ok, user}` on success, or `{:error, reason}` where `reason` is
  `:invalid` (bad or duplicate input) or `:insert_failed` (the database
  rejected the row).
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  @doc """
  Imports one user from `params`.

  Options:

    * `:notify` - send a welcome email (default `false`)
    * `:silent` - suppress the welcome email even when `:notify` is set
    * `:return_id` - return the new user's id instead of `{:ok, user}`
  """
  def import_user(params, opts \\ []) do
    with {:ok, email} <- normalize_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         :ok <- check_adult(age),
         {:ok, role} <- parse_role(params["role"]),
         :ok <- check_unique_email(email),
         {:ok, user} <- insert_user(email, age, role, params["nickname"]) do
      after_insert(user, opts)
    end
  end

  defp normalize_email(email) when is_binary(email), do: {:ok, String.downcase(email)}
  defp normalize_email(_), do: {:error, :invalid}

  # Ages above the maximum are capped rather than rejected.
  defp parse_age(age) when is_integer(age), do: {:ok, min(age, @max_age)}

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {n, ""} -> {:ok, min(n, @max_age)}
      _ -> {:error, :invalid}
    end
  end

  defp parse_age(_), do: {:error, :invalid}

  defp check_adult(age) when age >= @min_age, do: :ok
  defp check_adult(_), do: {:error, :invalid}

  # Only existing atoms are accepted, so outside input cannot grow the atom table.
  defp parse_role(role) when is_binary(role) do
    {:ok, String.to_existing_atom(role)}
  rescue
    ArgumentError -> {:error, :invalid}
  end

  defp parse_role(_), do: {:error, :invalid}

  defp check_unique_email(email) do
    if Repo.get_by(User, email: email), do: {:error, :invalid}, else: :ok
  end

  defp insert_user(email, age, role, nickname) do
    user = %User{email: email, age: age, role: role, nickname: nickname || email}

    case Repo.insert(user) do
      {:ok, user} -> {:ok, user}
      {:error, _changeset} -> {:error, :insert_failed}
    end
  end

  defp after_insert(user, opts) do
    if opts[:notify] && !opts[:silent], do: send_welcome(user)

    if opts[:return_id], do: user.id, else: {:ok, user}
  end

  defp send_welcome(user) do
    Task.start(fn -> Mailer.deliver(welcome_email(user)) end)
  end

  # Map.get/2 works on Ecto structs; bracket access does not, since they do not implement Access.
  defp welcome_email(user) do
    name = Map.get(user, :name) || "there"
    "Hi #{name}, welcome! Enjoy your account."
  end
end
