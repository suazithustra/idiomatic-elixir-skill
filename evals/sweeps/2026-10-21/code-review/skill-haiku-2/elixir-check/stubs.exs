defmodule Accounts.User do
  defstruct [:id, :email, :age, :role, :nickname]

  def changeset(struct, attrs) do
    data = Map.merge(struct, attrs)
    %{valid?: is_integer(data.age) and data.age >= 18, data: data}
  end
end

defmodule Accounts.Repo do
  def insert(%{valid?: true, data: data}), do: {:ok, %{data | id: 1}}
  def insert(changeset), do: {:error, changeset}
end

defmodule Mailer do
  def deliver(email), do: IO.puts("sent: #{email}")
end
