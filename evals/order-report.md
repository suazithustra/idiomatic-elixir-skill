# Order report

## Prompt

```text
Write an Elixir module `Reports.Orders` that takes a list of orders and builds a report. Orders come from a CSV parser as maps with string keys: "customer_id", "amount" (decimal string such as "19.99"), "currency" ("EUR", "USD", ...), "placed_at" (ISO 8601 datetime string), and "status" ("completed", "refunded", "pending").

The report needs, for each customer: total spent per currency across completed orders, and the date of their most recent order. It also needs the top 5 customers by number of completed orders.

Write the code to <output>/orders.ex. You may use the shell to check it compiles (Elixir <elixir-version> is installed; assume the `decimal` package is available if you want it, but you can't install it). Reply with just the file path when done.
```

## What to check

- Amounts are summed with `Decimal` or as integer minor units, never as floats.
- Dates are compared with `Date` or `DateTime` functions, or `Enum.max(dates, Date)`, not with `<`, `>`, or `Enum.max/1`.
- Specific `Enum` and `Map` functions are used where one fits (`Enum.frequencies_by/2`, `Map.new/2`, `Enum.sort_by/3`) instead of a hand-written `reduce`.
- If status strings are converted to atoms, it is done with explicit clauses.
- Lists are built with `Enum.map/2`, a comprehension, or prepend-and-reverse, not `acc ++ [order]` in a loop. Empty lists are checked with `== []` or a pattern, not `length(list) == 0`.
- One-call lambdas are captures (`&String.trim/1`, `& &1.amount`), not `fn x -> f(x) end`.
- No GenServer, Agent, or Task is introduced for what is a pure computation over the list.
- Boolean functions end in `?` (no `is_` names outside guards), and variables are named after the domain (`order`, `customer_id`, `totals`), not `data`, `res`, or `x`.
- The file passes `mix format --check-formatted`.
- Expected reads: none (SKILL.md only).

## Seen so far

Before 2026-10-21, undated:

- Without the skill: Opus and Sonnet were clean.
- Not yet run with the skill, or on Haiku.
