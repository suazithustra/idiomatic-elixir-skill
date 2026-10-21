# Stubs standing in for Ecto, the repo and the mailer.
defmodule Ecto.Changeset do
  defstruct [:data, constraints: []]
  def change(data), do: %__MODULE__{data: data}
  def unique_constraint(cs, field), do: %{cs | constraints: [field | cs.constraints]}
end

defmodule Accounts.User do
  defstruct [:id, :email, :age, :role, :nickname]
end

defmodule Accounts.Repo do
  def insert(%Ecto.Changeset{data: %{email: "dup@example.com"}} = cs), do: {:error, cs}
  def insert(%Ecto.Changeset{data: user}), do: {:ok, %{user | id: 1}}
end

defmodule Mailer do
  def deliver(text), do: send(:test_runner, {:delivered, text})
end

Code.require_file("improved.ex", __DIR__)

ExUnit.start()

defmodule Accounts.UserImporterTest do
  use ExUnit.Case
  alias Accounts.UserImporter

  setup do
    Process.register(self(), :test_runner)
    start_supervised!({Task.Supervisor, name: Accounts.TaskSupervisor})
    :ok
  end

  @valid %{"email" => " Bob@Example.com ", "age" => "30", "role" => "admin", "nickname" => ""}

  test "inserts a valid CSV row, lowercases email, falls back to email for blank nickname" do
    assert {:ok, user} = UserImporter.import_user(@valid)
    assert user.email == "bob@example.com"
    assert user.age == 30
    assert user.role == :admin
    assert user.nickname == "bob@example.com"
  end

  test "accepts an integer age from JSON and clamps it" do
    assert {:ok, %{age: 120}} = UserImporter.import_user(%{@valid | "age" => 150})
  end

  test "returns specific errors" do
    assert {:error, :invalid_email} = UserImporter.import_user(Map.delete(@valid, "email"))
    assert {:error, :invalid_email} = UserImporter.import_user(%{@valid | "email" => "  "})
    assert {:error, :invalid_age} = UserImporter.import_user(%{@valid | "age" => "3x"})
    assert {:error, :underage} = UserImporter.import_user(%{@valid | "age" => "17"})
    assert {:error, :invalid_role} = UserImporter.import_user(%{@valid | "role" => "root"})
    assert {:error, :invalid_role} = UserImporter.import_user(Map.delete(@valid, "role"))
  end

  test "returns the changeset on a failed insert" do
    assert {:error, %Ecto.Changeset{constraints: [:email]}} =
             UserImporter.import_user(%{@valid | "email" => "dup@example.com"})
  end

  test "sends the welcome email only when asked" do
    UserImporter.import_user(%{@valid | "nickname" => "Bob"}, notify: true)
    assert_receive {:delivered, "Hi Bob, welcome! Enjoy your account."}

    UserImporter.import_user(@valid)
    refute_receive {:delivered, _}
  end
end
