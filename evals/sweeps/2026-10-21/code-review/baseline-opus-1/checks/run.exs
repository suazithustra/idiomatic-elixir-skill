# Stubs standing in for Ecto, the repo, the schema and the mailer.
defmodule Ecto.Changeset do
  defstruct [:data, changes: %{}, constraints: []]
  @type t :: %__MODULE__{}
  def change(data, attrs), do: %__MODULE__{data: data, changes: Map.new(attrs)}
  def unique_constraint(cs, field), do: %{cs | constraints: [field | cs.constraints]}
end

defmodule Accounts.User do
  defstruct [:id, :email, :age, :role, :nickname]
end

defmodule Accounts.Repo do
  def insert(%Ecto.Changeset{changes: %{email: "taken@x.com"}} = cs), do: {:error, cs}
  def insert(%Ecto.Changeset{data: data, changes: changes}), do: {:ok, struct(data, Map.put(changes, :id, 1))}
end

defmodule Mailer do
  def deliver(body), do: send(:test_runner, {:delivered, body})
end

Code.require_file("user_importer.ex", __DIR__)

Process.register(self(), :test_runner)
{:ok, _} = Task.Supervisor.start_link(name: Accounts.TaskSupervisor)

alias Accounts.UserImporter

base = %{"email" => " Alice@Example.com ", "age" => "30", "role" => "member", "nickname" => ""}

cases = [
  {"happy path, CSV strings", base},
  {"JSON integer age", %{base | "age" => 30}},
  {"age capped", %{base | "age" => "150"}},
  {"underage", %{base | "age" => "17"}},
  {"negative age", %{base | "age" => "-3"}},
  {"bad age", %{base | "age" => "30abc"}},
  {"missing email", Map.delete(base, "email")},
  {"email without @", %{base | "email" => "nope"}},
  {"missing role", Map.delete(base, "role")},
  {"admin role rejected", %{base | "role" => "admin"}},
  {"duplicate email", %{base | "email" => "taken@x.com"}}
]

for {label, params} <- cases do
  IO.inspect(UserImporter.import_user(params), label: label)
end

{:ok, _} = UserImporter.import_user(%{base | "nickname" => "Al"}, notify: true)

receive do
  {:delivered, body} -> IO.inspect(body, label: "welcome email")
after
  1000 -> IO.puts("welcome email: NOT DELIVERED")
end
