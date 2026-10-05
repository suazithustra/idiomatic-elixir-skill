defmodule Accounts.UserImporter do
  # This module imports users from an external CSV/JSON source
  alias Accounts.{Repo, User}

  # Import a single user from the given params
  def import_user(params, opts \\ []) do
    # Get the role from params
    role = String.to_atom(params["role"])

    try do
      email = params["email"] |> String.downcase()
      age = String.to_integer(params["age"])

      if is_binary(email) && age >= 18 do
        user = %User{email: email, age: age, role: role}

        case Repo.insert(user) do
          {:ok, user} ->
            if opts[:notify] && !opts[:silent] do
              send_welcome(user)
            end

            if opts[:return_id], do: user.id, else: {:ok, user}

          _ ->
            {:error, :insert_failed}
        end
      else
        {:error, :invalid}
      end
    rescue
      _ -> {:error, :invalid}
    end
  end

  defp send_welcome(user) do
    # send the email
    spawn(fn -> Mailer.deliver(welcome_email(user)) end)
  end

  defp welcome_email(user) do
    name = user[:name] || "there"
    "Hi " <> name <> ", welcome!"
  end
end
