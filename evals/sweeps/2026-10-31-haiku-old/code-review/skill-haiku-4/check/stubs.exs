defmodule Accounts.User do
  defstruct [:id, :email, :age, :role, :nickname]
  def changeset(struct, attrs), do: Map.merge(struct, attrs)
end

defmodule Accounts.Repo do
  def insert(changeset), do: {:ok, changeset}
end

defmodule Mailer do
  def deliver(message), do: IO.puts(message)
end
