defmodule Accounts.UserImporterTest do
  use ExUnit.Case, async: false

  alias Accounts.{User, UserImporter}

  @valid %{"email" => "Ann@Example.COM", "age" => "30", "role" => "admin"}

  setup do
    Process.register(self(), :test_runner)
    :ok
  end

  test "imports a valid user, lowercasing email and defaulting nickname" do
    assert {:ok, %User{email: "ann@example.com", nickname: "ann@example.com", role: :admin}} =
             UserImporter.import_user(@valid)
  end

  test "clamps age to 120" do
    assert {:ok, %User{age: 120}} = UserImporter.import_user(%{@valid | "age" => "150"})
  end

  test "rejects minors, bad ages, unknown roles, and missing email" do
    assert {:error, %Ecto.Changeset{}} = UserImporter.import_user(%{@valid | "age" => "17"})
    assert {:error, %Ecto.Changeset{}} = UserImporter.import_user(%{@valid | "age" => "3x"})
    assert {:error, %Ecto.Changeset{}} = UserImporter.import_user(%{@valid | "role" => "root"})
    assert {:error, %Ecto.Changeset{}} = UserImporter.import_user(Map.delete(@valid, "email"))
  end

  test "keeps a given nickname" do
    assert {:ok, %User{nickname: "annie"}} =
             UserImporter.import_user(Map.put(@valid, "nickname", "annie"))
  end

  test "sends the welcome email only with notify: true" do
    UserImporter.import_user(@valid)
    refute_receive {:delivered, _}, 100

    UserImporter.import_user(@valid, notify: true)
    assert_receive {:delivered, "Hi there, welcome! Enjoy your account."}
  end

  test "rejects unknown options" do
    assert_raise ArgumentError, fn -> UserImporter.import_user(@valid, return_id: true) end
  end
end
