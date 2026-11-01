defmodule Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @max_age 120

  @doc false
  def changeset(user, attrs) do
    # The provider lowercases addresses before its uniqueness check, so match it here
    user
    |> cast(attrs, [:email, :age, :role, :nickname])
    |> update_change(:email, &String.downcase/1)
    |> update_change(:age, &min(&1, @max_age))
    |> put_default_nickname()
    |> validate_required([:email, :age, :role])
    |> validate_number(:age, greater_than_or_equal_to: 18)
    |> unique_constraint(:email)
  end

  defp put_default_nickname(changeset) do
    if get_field(changeset, :nickname) do
      changeset
    else
      put_change(changeset, :nickname, get_field(changeset, :email))
    end
  end
end
