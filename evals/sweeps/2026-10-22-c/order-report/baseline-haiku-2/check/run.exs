rows = [
  %{"customer_id" => "a", "amount" => "10", "currency" => "EUR", "placed_at" => "2024-01-02T10:00:00Z", "status" => "completed"},
  %{"customer_id" => "a", "amount" => "5", "currency" => "EUR", "placed_at" => "2024-02-02T10:00:00+02:00", "status" => "completed"},
  %{"customer_id" => "b", "amount" => "7", "currency" => "USD", "placed_at" => "2024-03-01T00:00:00", "status" => "refunded"}
]

IO.inspect(Reports.Orders.build(rows))
