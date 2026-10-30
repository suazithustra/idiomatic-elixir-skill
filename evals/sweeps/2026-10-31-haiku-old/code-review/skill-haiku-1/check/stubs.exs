defmodule Accounts.User do
  defstruct [:id, :email, :age, :role, :nickname]
  def changeset(user, attrs), do: Map.merge(user, attrs)
end

defmodule Accounts.Repo do
  def insert(struct), do: {:ok, Map.put(struct, :id, 1)}
end

defmodule Mailer do
  def deliver(_msg), do: :ok
end

defmodule Accounts.TaskSupervisor do
  def start_child(_sup, fun), do: fun.()
end
