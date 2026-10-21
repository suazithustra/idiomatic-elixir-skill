defmodule Accounts.User do
  defstruct [:id, :email, :age, :role, :nickname]
end

defmodule Accounts.Repo do
  # Fails for the email "taken@example.com" to exercise the error path.
  def insert(%Accounts.User{email: "taken@example.com"}), do: {:error, :taken}
  def insert(user), do: {:ok, %{user | id: 1}}
end

defmodule Mailer do
  def deliver(text), do: send(:test_probe, {:mail, text})
end

Process.register(self(), :test_probe)

Code.require_file("improved.ex", __DIR__)

alias Accounts.UserImporter, as: I

base = %{"email" => "A@Example.com", "age" => "150", "role" => "admin"}

IO.inspect(I.import_user(base), label: "clamped age")
IO.inspect(I.import_user(%{base | "age" => "17"}), label: "under 18")
IO.inspect(I.import_user(%{base | "role" => "bogus"}), label: "unknown role")
IO.inspect(I.import_user(Map.delete(base, "role")), label: "missing role")
IO.inspect(I.import_user(%{base | "age" => 30}), label: "integer age")
IO.inspect(I.import_user(%{base | "email" => nil}), label: "nil email")
IO.inspect(I.import_user(%{base | "email" => "taken@example.com"}), label: "db error")
IO.inspect(I.import_user(base, return_id: true), label: "return_id")

I.import_user(Map.put(base, "nickname", "Ann"), notify: true)
receive do
  {:mail, text} -> IO.puts("mail: " <> text)
after
  500 -> IO.puts("no mail sent")
end
