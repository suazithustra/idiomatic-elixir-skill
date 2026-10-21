defmodule U do
  defstruct [:nickname, :email]
end

defmodule Claims do
  def clamp(age) do
    if age > 120 do
      age = 120
    end

    age
  end
end

IO.inspect(Claims.clamp(150), label: "clamp(150)")

IO.inspect(
  (try do
     String.to_integer(30)
   rescue
     e -> e.__struct__
   end),
  label: "to_integer(30)"
)

IO.inspect(
  (try do
     struct(U, [])[:name]
   rescue
     e -> e.__struct__
   end),
  label: "struct[:name]"
)
