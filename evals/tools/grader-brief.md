# Grading brief

Fill in before use: `<repo>` (the repository), `<case>`, `<condition>` (`baseline` or `skill`), `<sweep>` (this sweep's folder, such as `<repo>/evals/sweeps/<date>`), `<previous>` (the previous sweep's folder, such as `<repo>/evals/sweeps/2026-10-21`), `<previous-revision>` (the short hash its record lines carry) and `<scratch>` (a scratch folder outside the repository).

You are grading the runs of one case in one condition against Elixir style rules. Read-only task: do not edit, create or delete any file inside the repository or the run folders, and do not run the `claude` command. You may run `elixir`, `mix` and read-only `git` commands (inside a run's project copy, compiling into `_build` is fine), and may write scratch files only under `<scratch>` (create it). The one file you write outside it is the grade file named at the end.

Repository: `<repo>`
- The rules: `idiomatic-elixir/SKILL.md` (each `###` heading is a rule; `## Naming` and `## Before you finish` are bullet-list rules) and `idiomatic-elixir/references/*.md` (each `##` heading is a rule, except "Other ExUnit features to reach for" in `ex_unit.md`, which is a list).
- The case: `evals/cases/<case>.md`. Its "What to check" list says what to look for. Its prompt is what the runs were given.
- The rule index: `evals/README.md`, the table headed "Which case exercises which rule". The rows whose "Cases" cell names the case are the rules to grade. Every one of them gets a verdict in every run, inside `verdicts`; the aggregation step refuses a grade file that lacks one. `other_violations` is only for rules outside that list.
- The standard: the previous sweep's two grade files for the case, `<previous>/grades/<case>-baseline.json` and `<previous>/grades/<case>-skill.json`, show the rule list, the verdict format and the kind of evidence expected. Run `git diff <previous-revision> -- idiomatic-elixir/` to see which rules changed since. Where a rule's text is unchanged, grade to the same standard as those files, so the sweeps can be compared. Where it changed, grade against the current text and say so in `notes`, naming the rule and the sentence that now decides the verdict.

The runs: `<sweep>/<case>/<condition>-*/`, one folder per run (`opus-1`, `haiku-1`, `haiku-2`, `sonnet-1`, `sonnet-2` in a sweep; no `opus` in a check batch). Each holds the output file(s), `prompt.txt`, the session transcript `transcript.jsonl.gz` (read it with `gzcat` or `zgrep`) and `result.json` with `model_id` (the identifier the transcript reports), `reads` (which skill files the session read, found by searching the transcript for a phrase unique to each file; `SKILL.md` means the main file), `files` (what the run wrote) and, where applicable, `format_ok`, `compiles` or `project` results. A run whose `rc` is `unavailable` (no model answered) gets the verdict `unavailable` for every rule and a summary that says so; a run with any other non-zero `rc` (`timeout`, `model mismatch`, `no transcript`, `skill not read`) is graded on whatever it wrote, and its summary says why it failed.

The condition: in a `baseline` run the prompt's last line told the session not to invoke any skills, so the runs show what the model does on its own. In a `skill` run the prompt's first line told the session to read SKILL.md and follow it, including the reference files it points to. Grade what is there, not what you would write. Do not lower the bar because the skill was present, and do not raise it because it was absent.

For every rule in the list and every run, give one verdict:
- "violated": the output contains the pattern the rule forbids. Quote the offending line(s) verbatim with the line number. A rule broken once in a file is still "violated".
- "clean": the output contains constructs the rule governs and follows the rule.
- "not exercised": the output contains no construct the rule governs.
- "unavailable": the run's `rc` is `unavailable`, so there is no output to judge.
Judge each run on its own. Be strict about evidence: a verdict of "violated" needs a verbatim quote; if you cannot quote it, the verdict is not "violated". Read each rule's full text before judging; do not grade from memory.

Also per run: the checks in the case's "What to check" list that were met or missed (one line each), including whether the "Expected reads" line is satisfied by `reads` in `result.json`; any other rule you see broken that is not in the case's list, with a verbatim quote; and, for a `skill` run, which skill files the transcript shows it reading (the `reads` field).

Write the JSON to `<sweep>/grades/<case>-<condition>.json` and return the same JSON as your reply, no prose before or after, in this shape:

```
{"case":"<case>","condition":"<condition>","notes":["..."],"runs":{"<condition>-opus-1":{"model_id":"...","reads":["SKILL.md",...],"format_ok":...,"verdicts":{"<rule heading>":{"verdict":"violated|clean|not exercised|unavailable","evidence":"line N: <verbatim>"}},"other_violations":["<rule>: line N: <verbatim>"],"checks":["met: ...","missed: ..."],"summary":"one sentence: what the run did, which rules it broke, which reference files it read"}},"per_rule":{"<rule heading>":{"opus":"violated|clean|not exercised|unavailable","haiku":"...","sonnet":"..."}}}
```

In `per_rule`, a tier is "violated" if any run of that tier violated, else "clean" if any run of that tier was clean, else "not exercised"; a tier with no run is "unavailable". The rule headings are the index's exact text, so `records.py` and `aggregate.py` can match them.
