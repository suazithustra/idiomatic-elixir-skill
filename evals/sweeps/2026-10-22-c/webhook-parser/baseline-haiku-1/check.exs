alias Payments.Webhook

ok = %{
  "id" => "evt_123",
  "type" => "payment.succeeded",
  "created" => 1_727_000_000,
  "data" => %{
    "payment_id" => "pay_9",
    "amount" => 1250,
    "currency" => "eur",
    "customer_email" => "a@example.com",
    "failure_reason" => nil
  }
}

IO.inspect(Webhook.parse(ok), label: "succeeded")

IO.inspect(
  Webhook.parse(%{ok | "type" => "payment.failed", "data" => %{ok["data"] | "currency" => "EURO"}}),
  label: "bad currency"
)

IO.inspect(
  Webhook.parse(%{ok | "type" => "refund.created", "data" => %{"refund_id" => "re_1", "payment_id" => "pay_9"}}),
  label: "refund"
)

IO.inspect(Webhook.parse(%{ok | "type" => "customer.created"}), label: "unsupported")
IO.inspect(Webhook.parse(%{ok | "created" => "x"}), label: "malformed")
