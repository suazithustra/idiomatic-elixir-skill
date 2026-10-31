defmodule Ecto.Changeset do
  defstruct data: nil, changes: %{}, errors: []

  def change(data, attrs), do: %__MODULE__{data: data, changes: Map.new(attrs)}
  def apply_changes(%__MODULE__{data: data, changes: changes}), do: struct(data, changes)
end

defmodule Accounts.User do
  defstruct [:id, :email, :age, :role, :nickname]

  def changeset(user, attrs), do: Ecto.Changeset.change(user, attrs)
end

defmodule Accounts.Repo do
  def insert(%Ecto.Changeset{errors: []} = cs), do: {:ok, Ecto.Changeset.apply_changes(cs)}
  def insert(%Ecto.Changeset{} = cs), do: {:error, cs}
end

defmodule Accounts.TaskSupervisor do
end

defmodule Mailer do
  def deliver(msg), do: IO.puts("mail: " <> msg)
end
