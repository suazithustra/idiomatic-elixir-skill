# Compile-time stand-in so user_importer.ex can be compiled without Ecto.
defmodule Accounts.User do
  defstruct [:email, :age, :role, :nickname]
end
