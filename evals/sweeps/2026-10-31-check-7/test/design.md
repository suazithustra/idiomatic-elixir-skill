# Nil-operand test: fixed before any run exists

Problem: code-review reviews report line 27, `opts[:notify] && !opts[:silent]`, under the `and`, `or`, `not`
rule. The case says that line is correct, because both values can be `nil`. The rule never says so.
Baseline on the previous batch, same models, same counts: 9 of 18 by blind graders, 9 of 18 mechanically.
Fix: "...truthy defaults such as `opts[:name] || "anonymous"` and for operands that can be `nil`, such as
`opts[:verbose]`, which `and` and `not` raise on." The example does not quote the case's line.

Runs: code-review, skill, Claude Code 2.1.314, 12 Haiku and 6 Sonnet, about $2.50.
Grading: blind under random ids, two graders with nine runs each, every rule in the case's current row.

Primary measure: reviews with a line 27 false positive, out of 18.
  3 or fewer: the clause works.
  7 or more: it does not.
  4 to 6: say so and add runs.
Guard: the clause must not stop reviews reporting the real `&&` on line 21. The `and`, `or`, `not` rule was
violated in 1 of 18 runs before; 3 or more now counts as harm, whatever the primary measure says.
Side effects: other rules per run (Haiku 1.75, Sonnet 1.50 before), planted problems (Haiku 18.9, Sonnet 19.7),
and the identical-errors misses (2 of 18).

## Second round, fixed after round one and before these runs

Round one, counted by hand because the first script dropped findings that cited review line 19:
line 27 false positives 6 of 18 (Haiku 0 of 12, Sonnet 6 of 6), against a corrected baseline of 11 of 18
(Haiku 6 of 12, Sonnet 5 of 6). That is in the 4 to 6 band, so the rule above says add runs.
Six more Haiku and six more Sonnet runs on the same text, pooled with round one, 30 runs, same blind grading.
Pooled bar, the same fractions as round one: 5 or fewer of 30 works, 12 or more does not, between stays open.
Added now, after seeing round one, so it is exploratory: reviews whose text writes `and` or `not` on those options.
