# Shop project

A task inside a Mix project that has Credo and tests. It checks whether agents run the formatter, compiler, Credo, and tests on their own, and how they handle user-typed strings and money.

## Setup

Requires Elixir 1.20 or later, Hex, and network access for `mix deps.get`. Make a fresh copy of `shop-project/` for every run (a run changes the project), then run `mix deps.get` in the copy. Before the run, confirm that `mix test` passes, `mix credo --strict` finds no issues, and `mix format --check-formatted` succeeds. Replace `<project>` below with the copy's path.

## Prompt

```text
The Mix project at <project> is a small shop app with a `Shop.Cart` module. Add the following to the cart:

- A way to remove units of an item from the cart. Removing more units than the cart holds removes the item.
- Discount codes. Customers type codes into a form, so they arrive as strings. "SAVE10" takes 10% off the item subtotal. "FREESHIP" waives the shipping fee. A cart can hold at most one code, and unknown codes must be rejected.
- A way to compute the total price in cents, given a price list that maps each SKU to its price in cents. Every order pays a shipping fee of 499 cents unless "FREESHIP" is applied.

Work inside that directory. Reply with a short summary of what you changed.
```

## What to check

From the run's transcript:

- It ran `mix format`, compiled, ran `mix credo --strict`, and ran `mix test`.

In the project afterwards:

- `mix format --check-formatted`, `mix compile --force --warnings-as-errors`, `mix credo --strict`, and `mix test` all pass.
- Discount codes are mapped to atoms with explicit clauses, or kept as strings. There is no `String.to_atom/1`.
- An unknown code returns an error with an atom, tagged tuple, or exception struct as the reason, not a string.
- The discount is computed with integer arithmetic, such as `div(subtotal * 90, 100)`, not with floats such as `trunc(subtotal * 0.9)`.
- `Shop.Cart` has functions that remove units, apply a code, and compute the total in cents. A second code is rejected or replaces the first; either way the cart holds one. Removing more units than present removes the item.
- With 2 units of `"APPLE"` at 100 cents each: no code gives 699, `"SAVE10"` gives 180 + 499 = 679, `"FREESHIP"` gives 200.
- The cart struct is updated with `%{cart | items: ...}`, not `Map.put/3`.
- Boolean functions end in `?`, and variables are named after the domain (`cart`, `sku`, `code`), not `data`, `res`, or `x`.
- Expected reads: `testing.md` when the run adds or changes tests.

## Seen so far

In the sweep of 2026-10-21, only commands starting with `mix`, `elixir` or `elixirc` were pre-approved, and the sessions could not answer a permission prompt. A few compound commands were refused (ones with shell variables, `find -exec`, `rm`, or a `python3` heredoc). No refused command was a run's only attempt at Credo or the compiler, so the records below stand.

Before 2026-10-21, undated:

- Haiku with the skill (2 runs): both ran the formatter, Credo, and the tests, and every final check passed. One added tests. Both computed the discount with floats.
- Haiku without the skill (2 runs): both ran the tests but neither ran Credo or the formatter, and both left unformatted code. Both returned string error reasons. One computed the discount with floats.
- Sonnet with the skill (1 run): ran everything, added tests, used integer arithmetic, and every final check passed.
- After the money rule gained the integer-arithmetic example (Haiku with the skill, 2 runs): both used `div(subtotal * 90, 100)`, and every final check passed. One run did not run Credo.

- 2026-10-21, 93873be, claude-opus-5-5, without skill, 1 run: Added remove_item/3, apply_discount/2 (explicit string clauses to atoms, atom error reasons, rejects a second code) and total_price/2 with integer div, plus tests; ran format, compile, test and credo --strict; broke none of the graded rules (sums with Enum.reduce where Enum.sum_by/2 fits).
- 2026-10-21, 93873be, claude-haiku-5-5, without skill, 1 run: Added remove_item/3, apply_discount/2 (keeps the code as a string, replaces an earlier code, atom error reason) and total_cents/2 with integer div, plus tests; ran only mix test and a format check, skipping compile and credo, so it broke Before you finish.
- 2026-10-21, 93873be, claude-haiku-5-5, without skill, 1 run: Added remove_item/3, apply_discount_code/2 (keeps the code as a string, replaces an earlier code, atom error reason) and total_cents/2 with integer div, plus tests; ran only mix test and a format check, skipping compile and credo, so it broke Before you finish.
- 2026-10-21, 93873be, claude-sonnet-5-5, without skill, 1 run: Added remove_item/3, apply_code/2 (explicit string clauses to atoms, rejects a second code, atom error reasons) and total_cents/2 returning {:ok, cents} with integer div, plus tests; ran mix format and mix test but not compile or credo, so it broke Before you finish.
- 2026-10-21, 93873be, claude-sonnet-5-5, without skill, 1 run: Added remove_item/3, apply_code/2 (one function clause per code string, rejects a second code, atom error reasons) and total_cents/2 returning {:ok, cents} with integer div, plus tests; ran mix format and mix test but not compile or credo, so it broke Before you finish.
- 2026-10-21, 93873be, claude-opus-5-5, with skill, 1 run: Added remove_item/3, apply_discount/2 (one function clause per code string, rejects a second code, tagged-tuple errors) and total_price/2 with integer div rounding halves up, plus tests and doctests; ran format, compile, credo --strict and test; broke none of the graded rules and no other rule; read SKILL.md, testing.md and library-design.md.
- 2026-10-21, 93873be, claude-haiku-5-5, with skill, 1 run: Added remove_item/3, apply_discount_code/2 (trims and upcases, explicit case clauses to atoms, replaces an earlier code, atom error reason) and total_cents/2 with integer div, plus tests; ran format, compile, test and credo --strict; broke none of the graded rules (one two-step pipeline written on one line); read SKILL.md and testing.md.
- 2026-10-21, 93873be, claude-haiku-5-5, with skill, 1 run: Added remove_item/3, apply_discount_code/2 (trims and upcases, explicit case clauses to atoms, replaces an earlier code, atom error reason) and total_cents/2 with integer div, plus tests; ran format, compile, test and credo --strict; broke none of the graded rules (one one-step with); read SKILL.md and testing.md.
- 2026-10-21, 93873be, claude-sonnet-5-5, with skill, 1 run: Added remove_item/3, apply_code/2 (one function clause per code string, rejects a second code, tagged-tuple errors) and total/2 returning {:ok, cents} with div(subtotal * 90, 100), plus tests and doctests; ran format, compile, credo --strict and test; broke none of the graded rules (two one-step with blocks); read SKILL.md only, not testing.md, although it added tests.
- 2026-10-21, 93873be, claude-sonnet-5-5, with skill, 1 run: Added remove_item/3, apply_discount/2 (one function clause per code string, rejects a second code, tagged-tuple errors) and total_price/2 returning {:ok, cents} with integer div rounding halves up, plus tests and doctests; ran format, compile, credo --strict and test; broke none of the graded rules (two one-step with blocks, one one-line test pipeline); read SKILL.md and testing.md.
