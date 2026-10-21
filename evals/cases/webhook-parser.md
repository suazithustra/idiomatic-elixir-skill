# Webhook parser

## Prompt

```text
In an Elixir application we receive webhook payloads from a payment provider. They arrive as JSON already decoded into maps with string keys, for example:

%{"id" => "evt_123", "type" => "payment.succeeded", "created" => 1727000000, "data" => %{"payment_id" => "pay_9", "amount" => 1250, "currency" => "eur", "customer_email" => "a@example.com", "failure_reason" => nil}}

Write a module `Payments.Webhook` that turns a payload into data the rest of the app can use. Event types we care about: payment.succeeded, payment.failed, refund.created (refunds carry "refund_id" and "payment_id" in data). Amounts are integer minor units. Add whatever modules and helper functions you think are right.

Write the code to <output>/webhook.ex. You may use the shell to check it compiles (Elixir <elixir-version> is installed). Reply with just the file path when done.
```

## What to check

- No `try/rescue` used to turn exceptions into tuples. Non-raising functions are used, such as `DateTime.from_unix/1` rather than `DateTime.from_unix!/1`.
- Error reasons are atoms, tagged tuples, or exception structs, not strings.
- No `String.to_atom/1` on the event type. Known types are mapped with explicit clauses.
- Selecting the event type is separate from validating its fields, so a known type with a missing field is not reported as an unsupported event.
- Missing-field and invalid-field errors name the actual field. They are not guessed from which other keys matched.
- Functions with several clauses bind in the head only what the clause's pattern or guard uses; fields the body alone needs are read from the matched value.
- Structs have `@enforce_keys` and `@type t`.
- Steps are chained with `with` over small private functions that return `{:ok, value}` or `{:error, reason}`. There is no large `else` block that maps errors back to steps.
- A `with` has at least two `<-` steps; a single fallible call is handled with `case`, and a second fallible call in the body is chained as a second step, not nested as a `case`.
- A function that checks a value and returns `{:error, reason}` is not named `fetch_*`; `fetch` names a lookup that returns `{:ok, value}` or `:error`. A variable may carry the name of the payload key it holds, such as `data` for `"data"`.
- No comments that restate a clause. Documentation is in `@moduledoc` and `@doc`.
- The file passes `mix format --check-formatted`.
- Expected reads: none (SKILL.md only).

## Seen so far

Before 2026-10-21, undated:

- Without the skill: Opus and Sonnet were clean. Haiku used `rescue` for control flow and returned string error reasons.
- With the skill: Haiku dropped both. One run let a known type with missing fields fall through to "unsupported event"; a later run guessed which field was missing. Both led to rule changes.

- 2026-10-21, 93873be, claude-opus-5-5, without skill, 1 run: Parses into an Event struct holding per-type structs, with explicit type clauses and with chains; broke the required-keys rule (Map.get in required/3), Naming (data) and Comments (a comment restating in_data/1).
- 2026-10-21, 93873be, claude-haiku-5-5, without skill, 1 run: Uses a Fields module of Map.fetch readers and per-type from_map/1 with with chains; broke match-every-shape (error -> error pass-throughs), Naming (data) and Comments (comments above public defs instead of @doc, from_map/1 undocumented).
- 2026-10-21, 93873be, claude-haiku-5-5, without skill, 1 run: Matches top-level keys in the head and maps types through a literal @kinds map; broke the required-keys and match-every-shape rules (Map.get plus _ -> reports missing fields as invalid), the struct rule (no @enforce_keys) and Naming (data).
- 2026-10-21, 93873be, claude-sonnet-5-5, without skill, 1 run: Builds per-type structs from pattern-based fetch_* helpers chained with with; broke match-every-shape and the struct rule (a clause that reports present non-map data as missing), the multi-clause rule (type bound in the head), Naming (data, a fetch_ that does not return :error) and Comments (struct modules lack @moduledoc).
- 2026-10-21, 93873be, claude-sonnet-5-5, without skill, 1 run: Matches all top-level keys in the head, maps types with event_type/1 clauses and validates fields with pattern-based helpers; broke match-every-shape (bare _ clauses), the multi-clause rule (id, type, created bound in the head), the struct rule (an inferred invalid field), Naming (data, dt) and Comments (parse/1 has no @doc).
- 2026-10-21, 93873be, claude-opus-5-5, with skill, 1 run: Parses into an Event struct holding Payment or Refund with a ParseError exception as the error reason and a parse!/1 wrapper; broke the multi-clause head rule (message/1 binds body-only fields) and Naming (data, a fetch_ function returning {:error, _}); read SKILL.md and library-design.md.
- 2026-10-21, 93873be, claude-haiku-5-5, with skill, 1 run: One struct per event type built from Map.fetch-based validators chained with with; broke only Naming (fetch_* functions that return {:error, _}), plus nested case/if outside the case list; read SKILL.md only.
- 2026-10-21, 93873be, claude-haiku-5-5, with skill, 1 run: An Event struct wrapping per-type data structs, built from Map.fetch validators chained with with; broke Naming (data, fetch_* returning {:error, _}) and Comments (a comment restating the code); read SKILL.md only.
- 2026-10-21, 93873be, claude-sonnet-5-5, with skill, 1 run: Builds PaymentEvent or RefundEvent from Map.fetch validators, with type and data matched in parse/1 heads; broke match-every-shape and the struct rule (a clause that infers the missing field; an else that turns missing into invalid), the with rule (that else), Naming (data, fetch_* returning {:error, _}) and Comments (a failing doctest); read SKILL.md only.
- 2026-10-21, 93873be, claude-sonnet-5-5, with skill, 1 run: An Event struct with Payment or Refund data, parse_type/1 clauses and Map.fetch validators chained with with; broke match-every-shape (a parse_data/2 catch-all) and Naming (data, fetch_* returning {:error, _}); read SKILL.md and library-design.md.
