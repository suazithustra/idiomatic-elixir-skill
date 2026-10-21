defmodule Accounts.User do
  @moduledoc false
  use Ecto.Schema

  schema "users" do
    field :email, :string
    field :age, :integer
    field :role, Ecto.Enum, values: [:admin, :member]
    field :nickname, :string
    field :name, :string
  end
end

defmodule Accounts.Repo do
  @moduledoc false

  def insert(changeset) do
    with {:ok, user} <- Ecto.Changeset.apply_action(changeset, :insert) do
      {:ok, %{user | id: 1}}
    end
  end
end

defmodule Accounts.Mailer do
  @moduledoc false

  def deliver(message) do
    send(:test_runner, {:delivered, message})
  end
end
