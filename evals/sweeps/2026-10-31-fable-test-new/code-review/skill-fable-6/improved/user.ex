defmodule Accounts.User do
  use Ecto.Schema

  import Ecto.Changeset

  @min_age 18
  @max_age 120

  schema "users" do
    field :email, :string
    field :age, :integer
    field :role, Ecto.Enum, values: [:admin, :member]
    field :nickname, :string
  end

  @doc """
  Builds the changeset for a user arriving from the external import source.
  """
  def import_changeset(user, params) do
    user
    |> cast(params, [:email, :age, :role, :nickname])
    # The provider lowercases addresses before its uniqueness check, so match it here
    |> update_change(:email, &String.downcase/1)
    |> validate_required([:email, :age, :role])
    |> validate_number(:age, greater_than_or_equal_to: @min_age, less_than_or_equal_to: @max_age)
    |> unique_constraint(:email)
    |> default_nickname()
  end

  defp default_nickname(changeset) do
    case get_field(changeset, :nickname) do
      nil -> put_change(changeset, :nickname, get_field(changeset, :email))
      _nickname -> changeset
    end
  end
end
