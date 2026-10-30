defmodule Accounts.User do
  defstruct [:id, :email, :age, :role, :nickname, :name]
end

defmodule Accounts.Repo do
  def get_by(_schema, _clauses), do: nil
  def insert(struct), do: {:ok, %{struct | id: 1}}
end

defmodule Mailer do
  def deliver(_), do: :ok
end
