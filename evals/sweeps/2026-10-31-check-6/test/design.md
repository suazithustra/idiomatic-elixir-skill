# Identical errors test: fixed before any run exists

Problem: code-review reviews leave the three identical `{:error, :invalid}` returns unreported.
Haiku and Sonnet, on the current text: 8 of 14 (sweeps 7 and 8, Haiku 4 of 4, Sonnet 2 of 4; Haiku test 2 of 6).
Fix: one sentence in "Match every expected shape": "Different failures need different reasons too:
a caller cannot tell a missing field from a bad number when both return `{:error, :invalid}`."

Runs: code-review, skill, Claude Code 2.1.314, 12 Haiku and 6 Sonnet, 18 runs, about $2.50.
Grading: blind under random ids, two graders with nine runs each, every rule in the case's current row.

Primary measure: runs violating "Match every expected shape", out of 18.
  3 or fewer: the sentence works.
  8 or more: it does not.
  4 to 7: say so and add runs.
Side effects: violations per run on the other 15 rules (Haiku 1.67, Sonnet 2.0 before),
planted problems reported, and any finding on a line the case's "Must not report" table protects.
