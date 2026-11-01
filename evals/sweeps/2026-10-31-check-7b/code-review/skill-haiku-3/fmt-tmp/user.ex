defmodule Accounts.User do
  use Ecto.Schema

  import Ecto.Changeset

  schema "users" do
    field(:email, :string)
    field(:age, :integer)
    field(:nickname, :string)
    field(:role, Ecto.Enum, values: [:admin, :editor, :member])

    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :age, :nickname, :role])
    |> validate_required([:email, :age, :role])
    # The provider lowercases addresses before its uniqueness check, so match it here
    |> update_change(:email, &String.downcase/1)
    |> validate_number(:age, greater_than_or_equal_to: 18)
    |> update_change(:age, &min(&1, 120))
    |> unique_constraint(:email)
  end
end
