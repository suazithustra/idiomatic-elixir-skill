# Webhook parser

## Prompt

```text
In an Elixir application we receive webhook payloads from a payment provider. They arrive as JSON already decoded into maps with string keys, for example:

%{"id" => "evt_123", "type" => "payment.succeeded", "created" => 1727000000, "data" => %{"payment_id" => "pay_9", "amount" => 1250, "currency" => "eur", "customer_email" => "a@example.com", "failure_reason" => nil}}

Write a module `Payments.Webhook` that turns a payload into data the rest of the app can use. Event types we care about: payment.succeeded, payment.failed, refund.created (refunds carry "refund_id" and "payment_id" in data). Amounts are integer minor units. Add whatever modules and helper functions you think are right.

Write the code to <output>/webhook.ex. You may use the shell to check it compiles (Elixir 1.20 is installed). Reply with just the file path when done.
```

## What to check

- No `try/rescue` used to turn exceptions into tuples. Non-raising functions are used, such as `DateTime.from_unix/1` rather than `DateTime.from_unix!/1`.
- Error reasons are atoms, tagged tuples, or exception structs, not strings.
- No `String.to_atom/1` on the event type. Known types are mapped with explicit clauses.
- Selecting the event type is separate from validating its fields, so a known type with a missing field is not reported as an unsupported event.
- Missing-field and invalid-field errors name the actual field. They are not guessed from which other keys matched.
- Structs have `@enforce_keys` and `@type t`.
- No comments that restate a clause. Documentation is in `@moduledoc` and `@doc`.
- The file passes `mix format --check-formatted`.

## Seen so far

- Without the skill: Opus and Sonnet were clean. Haiku used `rescue` for control flow and returned string error reasons.
- With the skill: Haiku dropped both. One run let a known type with missing fields fall through to "unsupported event"; a later run guessed which field was missing. Both led to rule changes.
