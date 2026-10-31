defmodule Decimal do
  # Minimal stub for compile/smoke checking only. The real package is not installed here.
  defstruct [:value]

  def new(s) when is_binary(s), do: %__MODULE__{value: String.to_float(s)}
  def add(%__MODULE__{value: a}, %__MODULE__{value: b}), do: %__MODULE__{value: a + b}
end
