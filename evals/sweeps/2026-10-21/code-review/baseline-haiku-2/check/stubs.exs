defmodule Accounts.User do
  defstruct [:id, :email, :age, :role, :nickname]
end

defmodule Accounts.Repo do
  def insert(%Accounts.User{email: "fail@x.com"}), do: {:error, :rejected}
  def insert(%Accounts.User{} = u), do: {:ok, %{u | id: 42}}
end

defmodule Mailer do
  def deliver(msg), do: send(:test_proc, {:mail, msg})
end

defmodule Accounts.TaskSupervisor do
  def start_child(_sup, fun), do: Task.start(fun)
end
