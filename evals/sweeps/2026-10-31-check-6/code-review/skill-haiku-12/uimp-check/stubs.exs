defmodule Accounts.User do
  defstruct [:id, :name, :email, :age, :role, :nickname]
  def changeset(s, attrs), do: Map.merge(s, attrs)
end

defmodule Accounts.Repo do
  def insert(s), do: {:ok, Map.put(s, :id, 1)}
end

defmodule Mailer do
  def deliver(e), do: IO.puts("mail sent: " <> e)
end

defmodule Accounts.TaskSupervisor do
  def start_child(_sup, fun), do: Task.start(fun)
end
