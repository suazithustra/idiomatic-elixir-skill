# Compile-time rule test: fixed before any run exists

Finding that prompted it: the `quote` rule's example passed an unexpanded alias into a module-body call
(a compile-time dependency), and the compile-time rule's example wrote an attribute inside `quote`.
Each taught the other's violation. Both examples now expand first and call a function.

Text: the working tree. Runs: macro-dsl, skill, Claude Code 2.1.314, 12 Haiku and 2 Sonnet.

Primary measure, mechanical: `mix xref trace` on the router, MyApp.PageHandler listed as compile or runtime,
over the 12 Haiku runs. Baseline: 23 of 24 compile (11 of 12 old text, 12 of 12 current).
  6 or fewer of 12 compile: the rewording works.
  10 or more of 12 compile: it does not.
  7 to 9: say so and add runs.
Side effects: a direct attribute write in `get`'s quote (baseline 3 of 12, mechanical count),
and blind grades on the seven unchanged-text rules (baseline mean 1.92 per run, of which compile-time 1.00).
