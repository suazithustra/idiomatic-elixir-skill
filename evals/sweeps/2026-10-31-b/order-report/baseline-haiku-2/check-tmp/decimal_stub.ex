defmodule Decimal do
  @type t :: integer()
  def new(s) when is_binary(s), do: round(String.to_float(s) * 100)
  def add(a, b), do: a + b
end
