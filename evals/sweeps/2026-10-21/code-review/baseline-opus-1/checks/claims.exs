defmodule U do
  defstruct [:email, :nickname]
end

age = 150

if age > 120 do
  age = 120
end

IO.inspect(age, label: "age after if")

check = fn label, fun ->
  result =
    try do
      fun.()
    rescue
      e -> e.__struct__
    end

  IO.inspect(result, label: label)
end

check.("struct access", fn -> URI.parse("http://x")[:name] end)
check.("to_integer(30)", fn -> String.to_integer(30) end)
check.("to_integer with space", fn -> String.to_integer(" 30") end)
check.("to_atom(nil)", fn -> String.to_atom(nil) end)
check.("Integer.parse 30abc", fn -> Integer.parse("30abc") end)
