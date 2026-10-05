# Shop project

A task inside a Mix project that has Credo and tests. It checks whether agents run the formatter, compiler, Credo, and tests on their own, and how they handle user-typed strings and money.

## Setup

Copy `shop-project/` to a scratch folder, then run `mix deps.get` in the copy. Before the run, confirm that `mix test` passes, `mix credo --strict` finds no issues, and `mix format --check-formatted` succeeds. Replace `<project>` below with the copy's path.

## Prompt

```text
The Mix project at <project> is a small shop app with a `Shop.Cart` module. Add the following to the cart:

- A way to remove units of an item from the cart.
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

## Seen so far

- Haiku with the skill (2 runs): both ran the formatter, Credo, and the tests, and every final check passed. One added tests. Both computed the discount with floats.
- Haiku without the skill (2 runs): both ran the tests but neither ran Credo or the formatter, and both left unformatted code. Both returned string error reasons. One computed the discount with floats.
- Sonnet with the skill (1 run): ran everything, added tests, used integer arithmetic, and every final check passed.
- After the money rule gained the integer-arithmetic example (Haiku with the skill, 2 runs): both used `div(subtotal * 90, 100)`, and every final check passed. One run did not run Credo.
