defmodule Stub do
  defstruct [:email, :age, :role, :nickname]
end

# 2. Does `user[:name]` work on a plain struct?
try do
  s = struct(Stub, email: "a@b", nickname: "x")
  IO.inspect(s[:name], label: "access result")
rescue
  e -> IO.puts("access raised: " <> Exception.message(e))
end

# 3. What does String.downcase(nil) do?
try do
  String.downcase(nil)
rescue
  e -> IO.puts("downcase raised: " <> Exception.message(e))
end
