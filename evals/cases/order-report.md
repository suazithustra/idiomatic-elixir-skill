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
- Specific `Enum` and `Map` functions are used where one fits (`Enum.frequencies_by/2`, `Enum.group_by/2`, `Map.new/2`, `Enum.sort_by/3`) instead of a hand-written `reduce`.
- If status strings are converted to atoms, it is done with explicit clauses.
- Lists are built with `Enum.map/2`, a comprehension, or prepend-and-reverse, not `acc ++ [order]` in a loop. Empty lists are checked with `== []` or a pattern, not `length(list) == 0`.
- One-call lambdas are captures (`&String.trim/1`, `& &1.amount`), not `fn x -> f(x) end`.
- No GenServer, Agent, or Task is introduced for what is a pure computation over the list.
- Boolean functions end in `?` (no `is_` names outside guards), and variables are named after the domain (`order`, `customer_id`, `totals`), not `data`, `res`, or `x`.
- A `with` has at least two `<-` steps; a single fallible call is handled with `case`, and a second fallible call in the body is chained as a second step, not nested as a `case`.
- The file passes `mix format --check-formatted`.
- Expected reads: none (SKILL.md only).

## Seen so far

Before 2026-10-21, undated:

- Without the skill: Opus and Sonnet were clean.
- Not yet run with the skill, or on Haiku.

- 2026-10-21, 93873be, claude-opus-5-5, without skill, 1 run: Parses rows into atom-keyed maps with Decimal amounts, DateTime values and explicit status clauses, returns {:ok, report} or the first row error, and breaks none of the case's rules (outside the list it lumps Decimal.parse/1 failures under `_ ->` and its @doc has no examples).
- 2026-10-21, 93873be, claude-haiku-5-5, without skill, 1 run: Parses rows into atom-keyed maps with integer cents and DateTime values and builds the report with group_by, Map.new and Enum.max(DateTime), breaking none of the case's rules, but it raises ArgumentError on malformed rows and fails mix format (a 99-character clause).
- 2026-10-21, 93873be, claude-haiku-5-5, without skill, 1 run: Groups the raw string-keyed maps by customer, sums integer cents per currency and takes the latest date with Enum.max(DateTime), breaking none of the case's rules, but it reads required keys with order["key"] inside the report code instead of parsing at the boundary and raises ArgumentError on bad input.
- 2026-10-21, 93873be, claude-sonnet-5-5, without skill, 1 run: Validates and folds orders into per-customer summaries in one reduce_while with Decimal totals and DateTime.compare/2, names a comparator's arguments a and b, and fails mix format (a 105-character line).
- 2026-10-21, 93873be, claude-sonnet-5-5, without skill, 1 run: Parses rows into atom-keyed maps with Decimal amounts and a completed? flag, then uses group_by, Map.new, Enum.max(DateTime) and frequencies_by, breaking none of the case's rules (outside the list it lumps Decimal.parse/1 failures under `_ ->` and its @doc has no examples).
- 2026-10-21, 93873be, claude-opus-5-5, with skill, 1 run: Parses rows into an Order struct with Decimal amounts, UTC DateTime values and explicit status clauses, returns the first bad row with its index, and builds the report with group_by, Map.new, Enum.max_by(DateTime) and frequencies_by, breaking none of the case's rules and no other rule found; it read SKILL.md and references/library-design.md.
- 2026-10-21, 93873be, claude-haiku-5-5, with skill, 1 run: Matches the required keys in the function head, parses into a %Reports.Orders{} struct with Decimal amounts and explicit status clauses, and builds the report with group_by, Map.new, Enum.max(Date) and frequencies_by, breaking none of the case's rules; outside the list it lumps Decimal.parse/1 failures under `_ ->` and puts a two-step pipeline on one line; it read SKILL.md only.
- 2026-10-21, 93873be, claude-haiku-5-5, with skill, 1 run: Parses rows into an Order struct with Decimal amounts and a Date, then folds them into per-customer summaries with Enum.reduce plus Map.get/Map.put and a hand-kept completed count, breaking the Enum/Map rule; outside the list it lumps Decimal.parse/1 failures under `_ ->` and its @doc has no examples; it read SKILL.md only.
- 2026-10-21, 93873be, claude-sonnet-5-5, with skill, 1 run: Parses rows into an Order struct with Decimal amounts and DateTime values, then folds them into summaries with Enum.reduce plus Map.get/Map.put and a hand-kept completed count, breaking the Enum/Map rule; outside the list it lumps Decimal.parse/1 failures under `_ ->`, starts two pipelines with a call or comprehension, and rewrites errors in a with/else; it read SKILL.md only.
- 2026-10-21, 93873be, claude-sonnet-5-5, with skill, 1 run: Parses rows into an Order struct with Decimal amounts and DateTime values, groups by customer with Map.new and takes the latest date with Enum.max(DateTime), breaking none of the case's rules; outside the list it lumps Decimal.parse/1 failures under `_invalid ->` and nests case inside with twice; it read SKILL.md only.
