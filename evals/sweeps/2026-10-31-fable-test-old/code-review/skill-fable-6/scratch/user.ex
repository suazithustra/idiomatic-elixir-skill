defmodule Accounts.User do
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "users" do
    field :email, :string
    field :age, :integer
    field :role, Ecto.Enum, values: [:admin, :member]
    field :nickname, :string
  end

  def changeset(user, params) do
    user
    |> cast(params, [:email, :age, :role, :nickname])
    |> validate_required([:email, :age, :role])
    |> unique_constraint(:email)
  end
end
