defmodule Decimal do
  @type t :: float()
  def new(v) when is_binary(v), do: v |> Float.parse() |> elem(0)
  def new(v) when is_integer(v), do: v * 1.0
  def add(a, b), do: a + b
end
