Mix.install([{:ecto, "~> 3.12"}])

defmodule Accounts.User do
  use Ecto.Schema

  schema "users" do
    field :email, :string
    field :age, :integer
    field :role, Ecto.Enum, values: [:admin, :member]
    field :nickname, :string
    field :name, :string
  end
end

defmodule Accounts.Repo do
  def insert(changeset), do: Ecto.Changeset.apply_action(changeset, :insert)
end

defmodule Mailer do
  def deliver(message), do: send(:check, {:delivered, message})
end

Code.require_file(Path.join(__DIR__, "user_importer.ex"))

Process.register(self(), :check)
{:ok, _} = Task.Supervisor.start_link(name: Accounts.TaskSupervisor)

alias Accounts.UserImporter

valid = %{"email" => "Ann@Example.com", "age" => "150", "role" => "member"}

{:ok, user} = UserImporter.import_user(valid, notify: true)
IO.inspect(user, label: "valid")
true = user.age == 120 and user.email == "ann@example.com" and user.nickname == "ann@example.com"

receive do
  {:delivered, message} -> IO.inspect(message, label: "delivered")
after
  1000 -> raise "no welcome email"
end

{:ok, _} = UserImporter.import_user(Map.put(valid, "nickname", "annie"))

receive do
  {:delivered, _} -> raise "sent without notify"
after
  100 -> :ok
end

for params <- [
      Map.put(valid, "age", "17"),
      Map.put(valid, "age", "abc"),
      Map.put(valid, "role", "superuser"),
      Map.delete(valid, "email"),
      Map.delete(valid, "role")
    ] do
  {:error, changeset} = UserImporter.import_user(params)
  IO.inspect(changeset.errors, label: inspect(params))
end

try do
  UserImporter.import_user(valid, silent: true)
  raise "accepted unknown option"
rescue
  ArgumentError -> IO.puts("unknown option rejected")
end

IO.puts("ok")
