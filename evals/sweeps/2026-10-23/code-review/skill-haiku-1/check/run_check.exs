defmodule Accounts.Repo do
  def insert(%Ecto.Changeset{valid?: true, changes: changes}) do
    {:ok, struct(Accounts.User, Map.put(changes, :id, 1))}
  end

  def insert(changeset), do: {:error, changeset}
end

defmodule Ecto.Changeset do
  defstruct [:data, :changes, valid?: true]
end

defmodule Accounts.User do
  defstruct [:id, :email, :age, :role, :nickname]

  def import_changeset(user, attrs) do
    valid? = is_binary(attrs.email)
    %Ecto.Changeset{valid?: valid?, data: user, changes: attrs}
  end
end

defmodule Mailer do
  def deliver(text), do: send(:test_proc, {:mail, text})
end

{:ok, _} = Task.Supervisor.start_link(name: Accounts.TaskSupervisor)
Process.register(self(), :test_proc)
Code.require_file("accounts/user_importer.ex", __DIR__)

alias Accounts.UserImporter

ok_params = %{"email" => "A@B.COM", "age" => "130", "role" => "admin"}
{:ok, user} = UserImporter.import_user(ok_params)
IO.inspect({user.email, user.age, user.role, user.nickname}, label: "clamped+downcased")

{:ok, _} = UserImporter.import_user(ok_params, notify: true)
receive do
  {:mail, text} -> IO.puts("mail: " <> text)
after
  1000 -> IO.puts("NO MAIL")
end

IO.inspect(UserImporter.import_user(%{"email" => "x@y.z", "age" => "abc", "role" => "admin"}), label: "bad age")
IO.inspect(UserImporter.import_user(%{"email" => "x@y.z", "age" => "17", "role" => "admin"}), label: "too young")
IO.inspect(UserImporter.import_user(%{"email" => nil, "age" => "30", "role" => "admin"}), label: "nil email")
IO.inspect(UserImporter.import_user(%{"email" => "x@y.z", "age" => "30", "role" => "root"}), label: "unknown role")
