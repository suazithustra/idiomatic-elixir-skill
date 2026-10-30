# Haiku side-by-side test: fixed before any run exists

Question: is the seventh sweep's Haiku rise caused by the skill text?

Arms: OLD = idiomatic-elixir at d04061d (4,635 words in SKILL.md).
      NEW = the working tree (6,659 words in SKILL.md).
Everything else is the same: claude-haiku-5-5, Claude Code 2.1.314, skill condition,
same prompts (identical since d04061d), six runs per arm per case, same hour.
Cases: code-review, macro-dsl, where the rise sits (3 to 10, 1 to 7).

Grading is blind: deliverables are copied to random ids, with `.formatter.exs` left out
because only NEW writes it. Four graders, two per case, each given three runs of each arm.

Primary measure, per run: violated verdicts on a fixed rule list.
  code-review: the 15 rules graded in the sixth sweep.
  macro-dsl: the 7 rules graded in the sixth sweep whose text has not changed
  (the `do:` row is left out because its text changed).
Secondary: planted problems reported in code-review, out of 21.

Reading the result (compare arm means per case, with a permutation test on the two arms):
  NEW above OLD by 1 or more per run: the text is the cause.
  Both arms near the sweep-7 level: not the text; the CLI or the model moved.
  Both arms near the sweep-6 level: sweep 7 was variation.
  Anything between: say so, and add runs before concluding.

## Second round, fixed after round one and before these runs

Round one: code-review OLD 1.83, NEW 2.00 per run; macro-dsl OLD 1.50, NEW 2.00.
macro-dsl fell between the sweep levels, so the rule above says add runs.

Six more runs per arm on macro-dsl, same design, pooled with round one (12 per arm).
Calibration: the real Haiku deliverables from the sixth and seventh sweeps go into the blind
pile, so the same graders score them. Sweep graders gave these, on the same rule lists:
  code-review sixth [1, 2], seventh [3, 7]; macro-dsl sixth [1, 0], seventh [3, 3].
If blind scores match, the sweep-7 runs really were worse and the spike was run-to-run variation.
If blind scores for the seventh-sweep runs are much lower, part of the spike was grader drift.
