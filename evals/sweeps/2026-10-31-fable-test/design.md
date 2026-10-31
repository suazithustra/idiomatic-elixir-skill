# Fable side-by-side test: fixed before any run exists

Question: do the changes since d04061d make the skill more or less effective for Fable?

Arms: OLD = idiomatic-elixir at d04061d (folder hash 005deae0).
      NEW = the working tree (folder hash 1fdf0c9b, the `with` edit included).
Everything else is the same: claude-fable-5-1, Claude Code 2.1.314, skill condition, same prompts.
Cases: code-review, macro-dsl, order-report, test-writing. Six runs per case per arm, 48 runs.
The two earlier probe runs are not counted.

Grading is blind and on Opus: deliverables are copied to random ids, with `.formatter.exs` left out
because only NEW writes it. Eight graders, two per case, each given three runs of each arm.
Every rule in each case's current index row is graded against the current text.

Measures, per run, violated verdicts on two fixed lists (fable-rule-lists.json):
  Older rules: the rules the sixth sweep graded for the case, without the `do:` row.
  Newer rules: the rest of the case's current row, the layout rules added or rewritten since.
Reading the result, comparing arm means with a permutation test:
  NEW above OLD by 0.5 or more per run on the older rules: the longer text costs Fable something.
  OLD above NEW by 0.5 or more per run on the newer rules: the changes help Fable.
  A smaller gap on either: no effect shown.
The threshold is 0.5, not the Haiku test's 1, because a strong model starts with few violations.

Budget: approved at about $90 to $110. OLD runs first. If its 24 runs cost more than $70,
stop before NEW and ask.

## Changed after the runs, before any grade

All six OLD macro-dsl runs wrote a `.formatter.exs`, though the old text has no such rule, so the file no longer
shows the arm. It stays in the blind copies and the `.formatter.exs` rule is graded from it.
