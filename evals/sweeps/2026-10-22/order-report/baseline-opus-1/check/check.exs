# Minimal stand-in for the decimal package, only for this local check.
defmodule Decimal do
  defstruct [:coef, :exp]
  @type t :: %__MODULE__{}

  def parse(string) do
    case Regex.run(~r/\A(-?\d+)(?:\.(\d+))?(.*)\z/s, string) do
      [_, int, frac, rest] -> {%Decimal{coef: String.to_integer(int <> frac), exp: -String.length(frac)}, rest}
      [_, int] -> {%Decimal{coef: String.to_integer(int), exp: 0}, ""}
      nil -> :error
    end
  end

  def add(%Decimal{} = a, %Decimal{} = b) do
    exp = min(a.exp, b.exp)
    scale = fn d -> d.coef * Integer.pow(10, d.exp - exp) end
    %Decimal{coef: scale.(a) + scale.(b), exp: exp}
  end

  def nan?(_), do: false
  def inf?(_), do: false
end

Code.require_file("../orders.ex", __DIR__)

rows = [
  %{"customer_id" => "a", "amount" => "19.99", "currency" => "EUR", "placed_at" => "2024-05-01T10:00:00Z", "status" => "completed"},
  %{"customer_id" => "a", "amount" => "5.01", "currency" => "EUR", "placed_at" => "2024-05-03T23:30:00-05:00", "status" => "completed"},
  %{"customer_id" => "a", "amount" => "7", "currency" => "USD", "placed_at" => "2024-05-02T10:00:00Z", "status" => "completed"},
  %{"customer_id" => "a", "amount" => "100", "currency" => "USD", "placed_at" => "2024-04-02T10:00:00Z", "status" => "refunded"},
  %{"customer_id" => "b", "amount" => "1.00", "currency" => "EUR", "placed_at" => "2024-06-01T10:00:00Z", "status" => "pending"},
  %{"customer_id" => "c", "amount" => "2.50", "currency" => "EUR", "placed_at" => "2024-01-01T10:00:00Z", "status" => "completed"}
]

IO.inspect(Reports.Orders.build(rows), label: "ok")
IO.inspect(Reports.Orders.build([%{"customer_id" => "x"}]), label: "missing")
IO.inspect(Reports.Orders.build([Map.put(hd(rows), "amount", "1.2x")]), label: "amount")
IO.inspect(Reports.Orders.build([Map.put(hd(rows), "placed_at", "2024-05-01T10:00:00")]), label: "offset")
IO.inspect(Reports.Orders.build([Map.put(hd(rows), "status", "shipped")]), label: "status")
IO.inspect(Reports.Orders.build([]), label: "empty")
