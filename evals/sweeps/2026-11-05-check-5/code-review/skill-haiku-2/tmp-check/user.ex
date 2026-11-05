defmodule Accounts.User do
  use Ecto.Schema

  import Ecto.Changeset

  @min_age 18
  @max_age 120

  schema "users" do
    field :email, :string
    field :age, :integer
    field :role, Ecto.Enum, values: [:admin, :editor, :member]
    field :nickname, :string

    timestamps()
  end

  @doc """
  Casts and validates a user built from imported params.

  Lowercases the email, caps the age at #{@max_age}, rejects ages under
  #{@min_age}, and turns a duplicate email into an error on `:email`.
  """
  def import_changeset(user, params) do
    user
    |> cast(params, [:email, :age, :role, :nickname])
    |> validate_required([:email, :age, :role])
    # The provider lowercases addresses before its uniqueness check, so match it here.
    |> update_change(:email, &String.downcase/1)
    |> update_change(:age, &min(&1, @max_age))
    |> validate_number(:age, greater_than_or_equal_to: @min_age)
    |> put_nickname()
    |> unique_constraint(:email)
  end

  defp put_nickname(changeset) do
    nickname = get_field(changeset, :nickname) || get_field(changeset, :email)
    put_change(changeset, :nickname, nickname)
  end
end
