defmodule Accounts.User do
  defstruct [:id, :email, :age, :role, :nickname, :name]

  def import_changeset(user, attrs), do: {user, attrs}
end

defmodule Accounts.Repo do
  def insert({user, attrs}) do
    if attrs["email"] == "taken@example.com" do
      {:error, :duplicate_email}
    else
      {:ok, struct(user, Map.put(attrs, :id, 1))}
    end
  end
end

defmodule Mailer do
  def deliver(text), do: send(:test_pid, {:mail, text})
end

defmodule Accounts.TaskSupervisor do
  def start_child(_sup, fun), do: {:ok, spawn(fun)}
end

Code.require_file("improved.ex")

params = %{"email" => "A@Example.com", "age" => "150", "role" => "admin"}
IO.inspect(Accounts.UserImporter.import_user(params), label: "clamp")
IO.inspect(Accounts.UserImporter.import_user(%{"email" => "b@x.com", "age" => "12", "role" => "admin"}), label: "underage")
IO.inspect(Accounts.UserImporter.import_user(%{"age" => "30", "role" => "admin"}), label: "missing email")
IO.inspect(Accounts.UserImporter.import_user(%{"email" => "c@x.com", "age" => "abc", "role" => "admin"}), label: "bad age")
IO.inspect(Accounts.UserImporter.import_user(%{"email" => "taken@example.com", "age" => "30"}), label: "insert fails")
IO.inspect(Accounts.UserImporter.import_user_id(%{"email" => "d@x.com", "age" => "30"}), label: "id")
