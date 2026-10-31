orders = [
  %{"customer_id" => "a", "amount" => "10.00", "currency" => "EUR", "placed_at" => "2026-01-02T10:00:00Z", "status" => "completed"},
  %{"customer_id" => "a", "amount" => "5.00", "currency" => "USD", "placed_at" => "2026-03-01T10:00:00+02:00", "status" => "refunded"},
  %{"customer_id" => "b", "amount" => "1.00", "currency" => "EUR", "placed_at" => "2026-02-01T10:00:00", "status" => "completed"}
]

IO.inspect(Reports.Orders.build(orders))
