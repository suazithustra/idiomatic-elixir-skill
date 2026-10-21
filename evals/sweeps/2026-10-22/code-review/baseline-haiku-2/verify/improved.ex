defmodule Accounts.UserImporter do
  @moduledoc """
  Imports users from an external CSV or JSON source.
  """

  alias Accounts.{Repo, User}

  @min_age 18
  @max_age 120

  # Maps role strings from the source to known atoms. Replace the list
  # with the roles your User schema accepts.
  @roles %{"admin" => :admin, "member" => :member}

  @doc """
  Imports one user from `params`.

  Returns `{:ok, user}`, or the new user's id when `:return_id` is set.
  Returns `{:error, :invalid}` for bad input and `{:error, :insert_failed}`
  when the database rejects the row.

  Options:

    * `:notify` - send a welcome email (default: `false`)
    * `:silent` - suppress the welcome email even when `:notify` is set
    * `:return_id` - return the new id instead of `{:ok, user}`
  """
  def import_user(params, opts \\ []) do
    with {:ok, email} <- parse_email(params["email"]),
         {:ok, age} <- parse_age(params["age"]),
         {:ok, role} <- Map.fetch(@roles, params["role"]) do
      user = %User{
        email: email,
        age: age,
        role: role,
        nickname: params["nickname"] || email
      }

      insert(user, opts)
    else
      _ -> {:error, :invalid}
    end
  end

  defp parse_email(email) when is_binary(email), do: {:ok, String.downcase(email)}
  defp parse_email(_), do: :error

  defp parse_age(age) when is_integer(age), do: check_age(age)

  defp parse_age(age) when is_binary(age) do
    case Integer.parse(age) do
      {value, ""} -> check_age(value)
      _ -> :error
    end
  end

  defp parse_age(_), do: :error

  # Ages above the maximum are capped, not rejected.
  defp check_age(age) when age >= @min_age, do: {:ok, min(age, @max_age)}
  defp check_age(_), do: :error

  defp insert(user, opts) do
    case Repo.insert(user) do
      {:ok, user} ->
        if opts[:notify] && !opts[:silent], do: send_welcome(user)

        if opts[:return_id], do: user.id, else: {:ok, user}

      {:error, _changeset} ->
        {:error, :insert_failed}
    end
  end

  defp send_welcome(user) do
    # Task.start/1 logs a crash; the earlier spawn/1 failed silently.
    Task.start(fn -> Mailer.deliver(welcome_email(user)) end)
  end

  defp welcome_email(user) do
    "Hi #{user.nickname}, welcome! Enjoy your account."
  end
end
