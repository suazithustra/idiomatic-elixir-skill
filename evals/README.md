# Evals

Fixed test prompts to rerun after changing the skill, to check that rules still work and nothing got worse. Nothing in `SKILL.md` points here, so agents using the skill never load these files.

## Cases

Each case is a file under `cases/`, next to any input it needs.

| File | Exercises |
| --- | --- |
| `webhook-parser.md` | external string-keyed input, error tuples, atom conversion |
| `rate-limiter.md` | shared state, processes, ETS, supervision |
| `order-report.md` | collections, decimals, date comparison |
| `library-client.md` | library options and configuration, error types |
| `macro-dsl.md` | macros, `use`, compile-time checks, library API |
| `test-writing.md` | ExUnit tests for a GenServer with an external dependency (`test-writing-input.ex`) |
| `ecto-phoenix.md` | changesets, preloads, migrations, transactions, contexts |
| `code-review.md` | reviewing a module with planted problems (`code-review-input.ex`) |
| `shop-project.md` | working inside a Mix project with Credo and tests (`shop-project/`) |

## Checking the skill

`elixir evals/check_skill.exs` checks the skill's code examples and this folder's rule index, and exits 1 on any failure. It runs every ` ```elixir ` block in `SKILL.md` and `references/` through three tiers: the whole block must parse, and a code fence that is never closed counts as a parse failure; each part of a wrong-then-right block (split at `# Instead of`, `# write`, and `# or`) must already be formatted; and each part that defines a module must compile without warnings. Two examples in `SKILL.md` are deliberate fragments that end in an open `do`; they are listed in the script and reported as skipped. It then checks that every rule heading has a row in the index below, that every row names a rule heading, that no row says "none yet", and that each phrase in the detection table occurs exactly once in the skill.

The checker cannot see a claim that is wrong or an example that compiles but misbehaves; those stay with review and the eval runs. `elixir evals/check_skill_test.exs` runs the checker's own tests. To add a fragment, add its file and heading to the list at the top of the script.

## Running a case

1. Copy the prompt from the case file. Replace `<output>` with a path in a scratch folder outside this repository, `<evals>` with a folder in that scratch space that holds only the case's input files from `cases/` (`code-review-input.ex`, `test-writing-input.ex`, `log-tests-input.ex`, or a fresh copy of `shop-project/`), `<skill>` with the path of the `idiomatic-elixir/` folder, and `<elixir-version>` with the installed version from `elixir --version`. Start the session with that scratch folder as its working directory, so the run cannot read the skill, this folder, or the "What to check" lists.
2. For every run, make sure the skill is not installed in any skills directory the session reads: move the folder or symlink out of the skills folder for the sweep and restore it after. Renaming it inside that folder is not enough, since every entry there is listed to the session as a skill under whatever name it has. A with-skill run must load only the copy the prompt names. For a run without the skill (baseline), add this line to the end of the prompt: `Do not invoke any skills.`
3. For a run with the skill, add this line to the start of the prompt: `First read the skill at <skill>/SKILL.md and follow it, including reading any reference file it points you to for this task.`
4. Run each prompt in a fresh session with no shared context. Smaller, faster models show the most problems. Run those at least twice, because results vary between runs. Keep each session's transcript; the next step searches it.

   A full sweep runs every case once on Opus, twice on Haiku and twice on Sonnet, without the skill first and then with it, and records every run. The scripts under `tools/` are the procedure of record (`tools/README.md` has the commands): `tools/sweep.py` runs the matrix, or a subset of cases and conditions, five sessions at a time, and `tools/run.py` runs one case in one condition. Both start each run as the sweep of 2026-10-21 did: a non-interactive session (`claude -p`, prompt on standard input) whose working directory is its own folder under a scratch root outside this repository, holding only the case's input files, with a copy of the skill folder granted read access for with-skill runs, and shell commands pre-approved only when they start with `mix`, `elixir` or `elixirc`; a non-interactive session cannot answer a permission prompt, so in that sweep a few compound commands (ones with shell variables, `find -exec`, `rm`, or a `python3` heredoc) were refused, which the shop-project records note. A run refuses to start while the skill is installed in the session's skills folder, whatever its condition. While a sweep or run lasts, the scripts also move every other entry of `~/.claude/skills/` and the synced plugins folder `~/.claude/plugins/synced/` (where a cloud session keeps its account's plugins) into `~/.claude/hidden-during-sweep/`, put them back afterwards, and start sessions without the variables that would fetch them again, so a session lists only the command line's built-in skills; `result.json` records the count as `skills_listed`. Plugins a user's settings enable are not in either folder and stay listed. Models are passed by identifier (`claude-opus-5-5`, `claude-haiku-5-5`, `claude-sonnet-5-5`); a run whose identifier the command line refuses is retried with the tier's alias and fails if its transcript reports another identifier. Each run's outputs, prompt and transcript are kept under `sweeps/<date>/<case>/<condition>-<tier>-<n>/` (the transcript gzipped) with a `result.json` whose fields `tools/README.md` lists under "What a run records". The gradings go under `sweeps/<date>/grades/`, one file per case and condition written from `tools/grader-brief.md` against the case's checks and the rule index one case at a time; `tools/records.py` then writes the record lines of the next section, and `tools/aggregate.py` folds the gradings into the index column, the violating-run counts and the cull lists, refusing when a grading lacks a verdict for a rule the index lists for its case.
5. Check the output against the case's "What to check" list, including its "Expected reads" line (see below). For a single-file case, run `mix format --check-formatted <output>/<file>.ex`, and compile with `elixir <output>/<file>.ex` where the case allows. For code-review, copy the improved module out of `review.md` into a `.ex` file first and run only the format check; the module does not compile on its own.

Step 3 tests whether agents follow the rules once they read them. It does not test whether an agent loads the skill by itself. To test that, install the skill and give the prompt without the extra line in a fresh session.

Each case ends with an "Expected reads" line naming the reference files a run should read for that task. To see which reference files a run read, search its transcript for a phrase that appears only in that file. Update these if the headings change.

| File | Phrase |
| --- | --- |
| `processes.md` | `Pick the abstraction that matches the job` |
| `library-design.md` | `Take configuration as arguments` |
| `ecto-phoenix.md` | `Keep migrations to schema changes` |
| `macros.md` | `Unquote each argument once` |
| `ex_unit.md` | `Wait for messages, not for time` |

Once per release, also run each case with the skill installed and without the line from step 3, to check that the agent loads the skill and the expected reference files by itself.

## Recording a run

Add one line per run, or per group of identical runs, under the case's "Seen so far", in this shape:

- `YYYY-MM-DD, <short hash>, <model identifier>, with skill or without skill, N runs: what happened, naming the rule that was broken or followed.`

The hash is the committed revision the skill was loaded from, with no uncommitted changes under `idiomatic-elixir/` or `evals/`. The model identifier is the exact name the session reports in its transcript, not the alias used to start it. Keep each transcript next to its outputs under `sweeps/<date>/`, gzipped, so the "Expected reads" phrases can be searched again later with `zgrep`. Notes written before this shape existed stay under the lead "Before 2026-10-21, undated:".

### Between sweeps

A rule has improved between two sweeps when its violating with-skill runs, counted across every case that exercises it, fell by at least two; a drop of one run is inside the variation above and is reported as unchanged. A rule that was clean with the skill has regressed when it has two or more violating with-skill runs in the later sweep; one run is recorded in the case file and not counted. When a rule's text changed between the sweeps, count each of its sentences on its own: a sentence the rewording allows no longer counts, and the sentences that remain carry the comparison. For a sentence the earlier sweep graded only in `other_violations`, that free text supplies its earlier count. `tools/aggregate.py --previous` prints these counts over the cases both sweeps graded for the rule, and says when the case sets differ; a count for a sentence the earlier sweep recorded only in `other_violations` is added by hand. The sweeps and check batches up to 2026-10-22 ran before the scripts hid other skills and plugins, with 210 skills listed to every session; a change between those sweeps and a later one partly reflects the shorter list, and `skills_listed` in each `result.json` shows which list a run had.

When a case is added to a rule's index row after a sweep was graded, that sweep's grades carry no verdict for the pair; `tools/aggregate.py` leaves the case out of that row and prints a note, and refuses only when some runs of a case have the verdict and others do not.

A check batch, which reruns one case with the skill (Haiku twice, Sonnet twice) while a rule is being reworded, lives under `sweeps/<date>-check/` in the same layout as a sweep, with one grades file per case; a batch rerun after a further rewording lives under `sweeps/<date>-check-2/`. Check batches get no record lines; the next sweep's lines supersede them. In the check batches of 2026-10-21 the one-step `with` sentence passed in webhook-parser, rate-limiter and shop-project but stayed at 2 of 4 runs in order-report after two rewordings, and the second sweep kept it at 2 of 5 there. A third rewording after that sweep, which names the public-function shape those runs wrote and shows it as the rule's example, passed 0 of 4 in the batch under `sweeps/2026-10-22-check/`; the same batch graded the pin and whole-value forms added to "Assert with patterns" at 0 of 4 in test-writing, and the captures rule, now allowing `&2` for one operator or call and naming `&3` as the limit, at 0 of 4 in order-report, where the three rules reworded in the previous round also held at 0 of 4. The `do:` rule, added after that batch, was first written with a flat clause-consistency sentence and a ban on any wrapped `do:` line; under `sweeps/2026-10-22-check-2/` it passed 0 of 4 in order-report but every macro-dsl run broke it, three on a four-clause `match_segments/3` with two short `do:` clauses and two block clauses, and three on a one-expression body whose long guard `mix format` wrapped onto a `do:` line. Both are shapes the rule should allow, so its last three sentences were reworded to keep short clauses on `do:` until most clauses need blocks and to accept a guard-wrapped head; under `sweeps/2026-10-22-check-3/` macro-dsl then had 2 of 4 runs, both Sonnet, keeping one `do:` clause in a three-clause `validate_path!/1` whose other two clauses are blocks, which is the case the sentence names. The sentence stays as written and the next sweep, which adds Opus and the without-skill runs, decides it.

The third sweep (`sweeps/2026-10-22-b/`, at 0397dec, the first run with other skills and plugins hidden) then measured all four rewordings. The one-step `with` sentence fell from 5 to 2 of 20 with-skill runs over its four cases: 0 of 5 in order-report and rate-limiter, one private one-step `with` in webhook-parser (sonnet-1) and, in shop-project, sonnet-1 writing twice the public shape the new sentence names. The pin form of "Assert with patterns" fell from 2 to 0 of 5, and the captures rule from 1 to 0 of 5, with order-report's sonnet-1 writing the `&Decimal.add(&1.amount, &2)` the rule now allows. The `do:` rule, measured for the first time with and without the skill, went from 3 of 10 runs without it to 2 of 10 with it: 0 of 5 in order-report, and in macro-dsl haiku-2 on a wrapped `do:` line and sonnet-1 on the clause-consistency case, one run where the check batch had two. The clause-consistency sentence stays as written. One rule regressed: "Group tests by function and name them by behaviour" went from 0 to 2 of 5 with-skill runs in test-writing, both on a test name (haiku-1's `test "returns :ok"`, the rule's own example, and sonnet-2's `test "succeeds when the topic has no subscribers"`), none on a `describe` block; it is the next rewording candidate.

After that sweep the test-name sentence of "Group tests by function and name them by behaviour" was rewritten, with `test "returns :ok"` moved into an Instead-of block, and the `do:` rule's last sentence now says that a `do:` body `mix format` moves onto its own line is too long for `do:`. Under `sweeps/2026-10-22-check-4/` both passed 0 of 4 (test-writing and macro-dsl, each 2 of 5 in the sweep), and the clause-consistency sentence was also at 0 of 4. One judgement the grader recorded: a Haiku run wrapped an `if ..., do:` line, which was left outside the rule because its sentences speak of function heads; the rule now says the same holds for `if`, with a wrapped `if ..., do: raise(...)` in its example. Under `sweeps/2026-10-22-check-5/` (macro-dsl) that sentence passed 0 of 4: both Haiku runs wrote validation `if`s whose branch would wrap as blocks, and the Sonnet runs validated with guards and wrote no `if`. One Haiku run broke the rule's unchanged second sentence with a two-step pipeline on `do:`, the shape of the rule's own Instead-of example; one run is inside the variation above, and the next sweep decides it.

Four additions were then checked together under `sweeps/2026-10-22-check-6/` (rate-limiter, ecto-phoenix, shop-project, test-writing and macro-dsl, with the skill): a new rule, "Build a multi-line argument under a name before the call"; a `defstruct` sentence in "Update structs"; a sentence in "Assert with patterns" putting the call under test on the left of `==`; and a new rule on the order of `use`, `import`, `alias` and `require`. The `defstruct` sentence passed 0 of 4 in shop-project, from 4 of 5 in the sweep. The `assert` sentence had 1 of 4 in test-writing, one Sonnet run writing `assert :ok == call` three times. The directive-order rule passed 0 of 4 everywhere, but macro-dsl and rate-limiter write one `use` and nothing else, so its index row names ecto-phoenix and test-writing, the cases whose modules open with several kinds. The named-argument rule failed for reasons in the skill's own text: in rate-limiter 3 of 4 runs wrote the `:ets.new/2` options inline across several lines, the shape the "Use ETS" example in `processes.md` showed, and in ecto-phoenix a clause covering an argument that "holds a call of its own" made a one-line `render(conn, :show, post: Blog.get_post!(id))` a violation. The example now names its options and the clause is gone; under `sweeps/2026-10-22-check-7/` the rule passed 0 of 4 in both cases, with every ETS run naming its options and every Ecto query and attrs map named before its call. In the same batch the test-naming rule, clean in check-4, had 2 of 4 Sonnet runs in test-writing, both on names the rule itself lists as bad; the next sweep decides whether the literal bad examples in its prose are priming the model.

A round from a review of real code followed, checked under `sweeps/2026-10-22-check-8/` (test-writing, the new log-tests case and code-review, with the skill): a new rule, "Capture logs with `capture_log/2`, not a handler", with log-tests as its case; a sentence in "Wait for messages" to match the exit reason in a `:DOWN` pattern; a sentence in "Assert with patterns" to put `assert` in front of a match in a test body; a planted lookup-before-insert in the code-review input, with the reviewing guidance in `SKILL.md` now also asking for code that builds by hand what a rule names a facility for; a note in "How to use" on loading the skill before writing; and the single-file forms of `mix test` in "Before you finish". The `capture_log` rule passed 0 of 4 (the grader ran each file against five mutants of the input to confirm the log assertions detect a wrong level or missing metadata), the exit-reason sentence 0 of 4, and all four reviews reported the planted lookup and replaced it with `unique_constraint/3`. The bare-match sentence had 2 of 4, both runs writing `:ok = subscribe(...)` bare as arrange steps, 22 and 26 times; it now names the arrange step and exempts a destructure that cannot fail, and the next sweep measures that wording. Two runs in log-tests called the logging function outside any capture in their return-value tests, so the rule now says to wrap every call that logs. The test-naming rule had 2 of 4 Sonnet runs for the second batch running, both on a `"returns :ok ..."` name. The planted problem changed the code-review input's line numbers and its planted count (21), so reported-problem counts before and after check-8 are not comparable; the rule verdicts are.

The fourth sweep (`sweeps/2026-10-22-c/`, at 3e3581d, ten cases with log-tests) measured the rounds since the third. The `capture_log` rule: 5 of 5 runs without the skill built a `:logger` handler by hand, Opus included, and four of them ran `async: false` because of it; 0 of 5 with the skill. The named-argument rule: 4 of 10 without the skill (every ecto-phoenix run but Opus passed its audit-log map inline), 1 of 10 with it. The `defstruct` sentence: 5 of 5 without, 0 of 5 with. The directive-order rule: 0 of 10 in both conditions, so it enters the cull list at once. The rewritten `do:` sentences and the `if` sentence were broken by no with-skill run; the rule's 2 of 10 with the skill both fall on the unchanged clause-consistency sentence, a three-clause `validate_path!/1` in macro-dsl keeping one `do:` clause beside two blocks (Opus and Sonnet), the shape of check-3 and the third sweep, so that sentence is the next rewording. The test-name sentence: 1 of 5 in test-writing (a Haiku `"returns :ok"`), from 2 of 5. The exit-reason sentence: 0 of 5. The bare-match sentence in its final wording: 0 of 5 in test-writing and in log-tests, where 3 of 5 test-writing runs without the skill wrote the bare `:ok = subscribe(...)` arrange step 24 to 37 times each. The `==` order sentence: 2 of 5 in log-tests, its first measurement, both with the expected value on the left. The review plant: all five reviews without the skill reported the lookup and two Haiku runs kept it in their improved code; all five with the skill reported it and replaced it with `unique_constraint/3`. Naming regressed from 0 to 2 of 20 with the skill on two single-run shapes (an Opus `n` for a limit, a Haiku `fetch_field/3`), and "Assert with patterns" reads as regressed because log-tests joined its row; over test-writing alone it is 1 of 5. Sessions were shown 29 skills (16 in the first five runs).

After the fourth sweep the `==` sentence of "Assert with patterns" was rewritten to name the value under test, a call or a result bound a line earlier, with an Instead-of pair in the example; `references/testing.md` became `references/ex_unit.md`, since every rule in it is about tests written with ExUnit, and its trigger in `SKILL.md` now names any task that writes, changes, runs or reviews a test. Under `sweeps/2026-10-22-check-9/` the sentence passed 0 of 4 in log-tests (2 of 5 in the sweep), and all four shop-project runs read `ex_unit.md` before their first edit to a test file (2 of 5 in the sweep).

A further round, checked under `sweeps/2026-10-22-check-10/` (ecto-phoenix, rate-limiter, macro-dsl and shop-project, with the skill): the `do:` rule now says a function may mix the forms, with each block clause set apart by a blank line, in place of the clause-consistency sentence the fourth sweep's two runs broke; the named-argument rule's prose was rewritten twice, first to cover a call whose result is discarded (the `:ok = :logger.add_handler(...)` shape the rule's example shows), then, after rate-limiter's sonnet-1 nested a keyword list inside a map it built under a name, to say that a call with its own options nested inside a literal becomes a name too; and a "Formatting" bullet under "How to use this skill" asks for `mix format` on each file as it is finished, with step 1 of "Before you finish" pointing at it. The `do:` rewording was broken by no run, but no macro-dsl run wrote a function that mixes the forms, so the next sweep decides it. The named-argument rule passed 0 of 4 in ecto-phoenix, the case where 4 of 5 runs broke it without the skill; in rate-limiter (1 of 5 with the skill in the sweep) the one run that failed wrote the shape the second rewording now names. The Formatting bullet moved every shop-project run from a project-wide `mix format` (3 of 5 in the sweep) to one naming the two changed files, but all four ran it once at the end, after edits to both, so the case's new check line on the timing passed 0 of 4. The bullet was then rewritten to state the sequence: a file is formatted after its last edit and before the session edits another file or runs the tests, and formatted again when it is edited again.

The "Without skill" column holds the latest sweep; an earlier sweep's values stay in its `grades/` folder. After a second sweep, a candidate is confirmed when Opus and Sonnet were clean without the skill in both sweeps, dropped when either violated the rule without the skill in the later one, and unconfirmed when either was unavailable or never produced the construct in the later one; Haiku's value is printed with each candidate but does not decide, and the cull section says why.

Tiers are named by model identifier, the exact name the transcript reports. A run starts with that identifier and falls back to the tier's alias only when the command line refuses it; a transcript that names another model fails the run, and a tier with no accepted route is unavailable, which leaves its rows unconfirmed when the tier is Opus or Sonnet.

## Which case exercises which rule

A rule with no case can regress unnoticed. The rule cell is the rule's exact heading, which `check_skill.exs` matches against the skill; rows follow `SKILL.md`, then the reference files in alphabetical order. The cases cell names the cases that check the rule, or starts with "not provocable:" and says why no neutral prompt can. The "Without skill" cell is filled from the sweep: for each tier, violated, clean, not exercised, or unavailable.

| Rule | Cases | Without skill |
| --- | --- | --- |
| Read required keys with `map.key` or a pattern; keep `map[:key]` for optional keys | code-review, webhook-parser | Opus clean, Haiku violated, Sonnet violated |
| Match every expected shape and let unexpected ones crash | code-review, webhook-parser | Opus violated, Haiku violated, Sonnet violated |
| In multi-clause functions, bind in the head only what patterns and guards use | webhook-parser | Opus violated, Haiku violated, Sonnet violated |
| Update structs with `%{struct \| field: value}` | shop-project | Opus violated, Haiku violated, Sonnet violated |
| Convert external strings to atoms with explicit clauses | webhook-parser, order-report, shop-project, code-review | Opus clean, Haiku clean, Sonnet clean |
| Branch with function clauses and guards before reaching for `if` or `cond` | rate-limiter, code-review | Opus clean, Haiku violated, Sonnet clean |
| Chain fallible steps with `with`; normalize each step's error in a small private function | webhook-parser, shop-project, rate-limiter, order-report | Opus violated, Haiku violated, Sonnet violated |
| Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs | webhook-parser, library-client, shop-project, code-review | Opus clean, Haiku clean, Sonnet clean |
| Use `and`, `or`, `not` when the operands are booleans | code-review | Opus violated, Haiku violated, Sonnet violated |
| Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it | code-review | Opus clean, Haiku clean, Sonnet clean |
| Use the `Enum` or `Map` function made for the job | order-report | Opus violated, Haiku clean, Sonnet violated |
| Treat lists as linked lists | order-report | Opus clean, Haiku clean, Sonnet clean |
| Compare dates, times, and decimals with their module functions | order-report | Opus clean, Haiku clean, Sonnet clean |
| Store and compute money as integer minor units or `Decimal`, never floats | order-report, shop-project | Opus clean, Haiku clean, Sonnet clean |
| Parse external data into structs where it enters the system | webhook-parser | Opus clean, Haiku clean, Sonnet clean |
| Use one atom-valued field or option instead of overlapping booleans | code-review | Opus clean, Haiku violated, Sonnet clean |
| Group related parameters | library-client | Opus clean, Haiku violated, Sonnet violated |
| Give each function one return shape | library-client, code-review | Opus clean, Haiku violated, Sonnet clean |
| Read configuration at runtime, not into module attributes | library-client | Opus clean, Haiku clean, Sonnet clean |
| Naming | rate-limiter, webhook-parser, order-report, shop-project | Opus violated, Haiku violated, Sonnet violated |
| Comments explain why; documentation goes in `@moduledoc` and `@doc` | code-review, webhook-parser, rate-limiter | Opus violated, Haiku violated, Sonnet violated |
| Keep functions short and at one level of detail | code-review | Opus clean, Haiku violated, Sonnet clean |
| Build a multi-line argument under a name before the call | rate-limiter, ecto-phoenix | Opus clean, Haiku violated, Sonnet violated |
| Use `do:` for a one-expression body and `do ... end` for anything else | order-report, macro-dsl | Opus violated, Haiku violated, Sonnet violated |
| Write pipelines that start with a value and read top to bottom | code-review | Opus violated, Haiku violated, Sonnet violated |
| Use captures for one-call lambdas and `fn` for anything longer | order-report | Opus clean, Haiku clean, Sonnet violated |
| Open a module with `use`, `import`, `alias`, `require`, in that order | ecto-phoenix, test-writing | Opus clean, Haiku clean, Sonnet clean |
| Before you finish | shop-project | Opus clean, Haiku violated, Sonnet violated |
| Validate input with changesets | ecto-phoenix, code-review; the accessor sentence is not provocable: no prompt needs to know whether a field changed | Opus violated, Haiku violated, Sonnet violated |
| Let Phoenix turn missing records into 404 responses | ecto-phoenix | Opus clean, Haiku clean, Sonnet clean |
| Group writes that must succeed together | ecto-phoenix | Opus clean, Haiku clean, Sonnet clean |
| Load associations up front | ecto-phoenix | Opus clean, Haiku clean, Sonnet clean |
| Keep migrations to schema changes | ecto-phoenix | Opus violated, Haiku violated, Sonnet violated |
| Keep database access in contexts | ecto-phoenix | Opus clean, Haiku clean, Sonnet clean |
| Take configuration as arguments, not from the application environment | library-client | Opus clean, Haiku violated, Sonnet clean |
| Use exception structs as error reasons | library-client | Opus clean, Haiku violated, Sonnet clean |
| Make polymorphism explicit | library-client | Opus violated, Haiku violated, Sonnet violated |
| Add specs, and hide technical functions from the docs | library-client, macro-dsl | Opus violated, Haiku violated, Sonnet violated |
| Keep secrets out of logs and inspect output | library-client | Opus violated, Haiku not exercised, Sonnet violated |
| Keep structs under 32 fields | not provocable: no prompt builds a struct with that many fields | not provocable |
| Write a function unless the job needs a macro | macro-dsl | Opus clean, Haiku clean, Sonnet clean |
| Keep `quote` blocks small | macro-dsl | Opus violated, Haiku violated, Sonnet violated |
| Unquote each argument once | macro-dsl | Opus clean, Haiku clean, Sonnet clean |
| Offer `import` or `alias` instead of `use` when they are enough | macro-dsl; the import-instead-of-use sentence is not provocable: the prompt prescribes `use TinyRouter` | Opus violated, Haiku violated, Sonnet violated |
| Avoid compile-time dependencies on modules used only at runtime | macro-dsl | Opus violated, Haiku violated, Sonnet violated |
| Write module names literally | macro-dsl | Opus clean, Haiku clean, Sonnet clean |
| Decide whether you need a process | order-report | Opus clean, Haiku clean, Sonnet clean |
| Pick the abstraction that matches the job | rate-limiter; the timeout sentence is not provocable: no prompt maps concurrently | Opus violated, Haiku violated, Sonnet violated |
| Keep each process behind one module | rate-limiter | Opus violated, Haiku clean, Sonnet clean |
| Write GenServers that stay responsive | rate-limiter | Opus clean, Haiku clean, Sonnet clean |
| Use ETS for data many processes read | rate-limiter | Opus violated, Haiku violated, Sonnet violated |
| Supervise every long-lived process | rate-limiter, code-review | Opus clean, Haiku violated, Sonnet clean |
| Send processes only the data they need | code-review | Opus violated, Haiku violated, Sonnet violated |
| Run tests concurrently unless they share global state | test-writing, log-tests | Opus violated, Haiku violated, Sonnet violated |
| Group tests by function and name them by behaviour | test-writing, log-tests | Opus violated, Haiku violated, Sonnet violated |
| Assert with patterns | test-writing, log-tests | Opus violated, Haiku violated, Sonnet violated |
| Wait for messages, not for time | test-writing | Opus clean, Haiku violated, Sonnet violated |
| Start processes with `start_supervised!/1` | test-writing | Opus clean, Haiku violated, Sonnet violated |
| Replace dependencies at boundaries, through behaviours | test-writing, log-tests | Opus clean, Haiku clean, Sonnet clean |
| Use setup for shared data | test-writing | Opus clean, Haiku clean, Sonnet clean |
| Capture logs with `capture_log/2`, not a handler | log-tests; the primary-level sentence is not provocable: a plain `elixir` run logs at `:debug` | Opus violated, Haiku violated, Sonnet violated |

## Cull candidates

A rule Opus and Sonnet followed without the skill is a candidate for deletion, not a deletion: with five runs per case, a rule broken in a third of runs shows clean about one time in six. Haiku's result is printed with each candidate but does not decide it: Haiku is rarely the model given the work the skill is for, and it breaks rules the other two keep, so counting it would drop rules the skill's readers already see followed. The first two comparisons let every tier decide; the rule changed after the third sweep, where under the old one five rows would have dropped on Haiku alone. Delete a rule only after a later sweep, on a later date, agrees. The lists below compare the fourth sweep, 2026-10-22-c at 3e3581d, kept under `sweeps/2026-10-22-c/`, with the third, 2026-10-22-b at 0397dec, kept under `sweeps/2026-10-22-b/`; every tier was available in both, and the earlier comparisons are in this file's history (the third sweep against the second at 192abf3, the second against the first at 8d4ba29). A rule is confirmed when Opus and Sonnet were clean without the skill in both sweeps, dropped when either violated it without the skill in the later one, and unconfirmed when either was unavailable or never produced the construct in the later one. Of the four dropped rows, "Update structs" fell to the `defstruct` sentence added after the third sweep, which every run without the skill breaks and every run with it keeps, so the drop is the sentence doing its job; "Assert with patterns" to its two new sentences and to log-tests joining its row; the captures rule to one Sonnet run's two-call capture; and "Keep each process behind one module" to one Opus run's partitioned design.

Confirmed (a candidate in both sweeps):
- Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it: Opus 1 run, Sonnet 2 in code-review; Haiku clean
- Compare dates, times, and decimals with their module functions: Opus 1 run, Sonnet 2 in order-report; Haiku clean
- Convert external strings to atoms with explicit clauses: Opus 1 run, Sonnet 2 in code-review, order-report, shop-project, webhook-parser; Haiku clean
- Decide whether you need a process: Opus 1 run, Sonnet 2 in order-report; Haiku clean
- Give each function one return shape: Opus 1 run, Sonnet 2 in code-review, library-client; Haiku violated
- Group writes that must succeed together: Opus 1 run, Sonnet 2 in ecto-phoenix; Haiku clean
- Keep database access in contexts: Opus 1 run, Sonnet 2 in ecto-phoenix; Haiku clean
- Let Phoenix turn missing records into 404 responses: Opus 1 run, Sonnet 2 in ecto-phoenix; Haiku clean
- Load associations up front: Opus 1 run, Sonnet 2 in ecto-phoenix; Haiku clean
- Read configuration at runtime, not into module attributes: Opus 1 run, Sonnet 2 in library-client; Haiku clean
- Replace dependencies at boundaries, through behaviours: Opus 1 run, Sonnet 2 in log-tests, test-writing; Haiku clean
- Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs: Opus 1 run, Sonnet 2 in code-review, library-client, shop-project, webhook-parser; Haiku clean
- Store and compute money as integer minor units or `Decimal`, never floats: Opus 1 run, Sonnet 2 in order-report, shop-project; Haiku clean
- Supervise every long-lived process: Opus 1 run, Sonnet 2 in code-review, rate-limiter; Haiku violated
- Take configuration as arguments, not from the application environment: Opus 1 run, Sonnet 2 in library-client; Haiku violated
- Treat lists as linked lists: Opus 1 run, Sonnet 2 in order-report; Haiku clean
- Unquote each argument once: Opus 1 run, Sonnet 2 in macro-dsl; Haiku clean
- Use exception structs as error reasons: Opus 1 run, Sonnet 2 in library-client; Haiku violated
- Write a function unless the job needs a macro: Opus 1 run, Sonnet 2 in macro-dsl; Haiku clean
- Write module names literally: Opus 1 run, Sonnet 2 in macro-dsl; Haiku clean

Dropped (a candidate the previous sweep had; Opus or Sonnet violated it in this one):
- Assert with patterns: Opus violated, Haiku violated, Sonnet violated in log-tests, test-writing
- Keep each process behind one module: Opus violated, Haiku clean, Sonnet clean in rate-limiter
- Update structs with `%{struct | field: value}`: Opus violated, Haiku violated, Sonnet violated in shop-project
- Use captures for one-call lambdas and `fn` for anything longer: Opus clean, Haiku clean, Sonnet violated in order-report

Unconfirmed (a candidate the previous sweep had; Opus or Sonnet did not exercise it this time):
- none

New candidates (clean on Opus and Sonnet this sweep, not a candidate before):
- Branch with function clauses and guards before reaching for `if` or `cond`: Opus 1 run, Sonnet 2 in code-review, rate-limiter; Haiku violated
- Keep functions short and at one level of detail: Opus 1 run, Sonnet 2 in code-review; Haiku violated
- Open a module with `use`, `import`, `alias`, `require`, in that order: Opus 1 run, Sonnet 2 in ecto-phoenix, test-writing; Haiku clean
- Parse external data into structs where it enters the system: Opus 1 run, Sonnet 2 in webhook-parser; Haiku clean
- Use one atom-valued field or option instead of overlapping booleans: Opus 1 run, Sonnet 2 in code-review; Haiku violated
- Use setup for shared data: Opus 1 run, Sonnet 2 in test-writing; Haiku clean
- Write GenServers that stay responsive: Opus 1 run, Sonnet 2 in rate-limiter; Haiku clean

Unconfirmed (Opus or Sonnet never produced the construct the rule governs):
- none

### Decision after the fourth sweep

Twenty rules are confirmed, and all stay in the skill. The sweeps ran Claude models only (`claude-opus-5-5`, `claude-haiku-5-5`, `claude-sonnet-5-5`), and the skill is published for any model, so a rule is deleted only when a sweep on other commonly used models agrees. `tools/run.py` starts `claude -p` sessions; another model needs a runner of its own that leaves the same run folders, so the grading and aggregation steps can stay as they are.

Nineteen of the 20 were confirmed after the third sweep too, so each has been clean on Opus and Sonnet in at least three sweeps; "Take configuration as arguments, not from the application environment" was a new candidate then. Seven new candidates appear, among them "Open a module with `use`, `import`, `alias`, `require`, in that order", added in this round and clean in every run with and without the skill in its first measurement: a rule the models follow unasked, kept for now like the others. The two candidates the third sweep added, "Assert with patterns" and the captures rule, dropped again, which is what one clean sweep on one case is worth.

Three cautions apply even for Claude. Fourteen of the 20 rules were exercised by one case, and some of those prompts leave little room to break the rule: order-report hands the model decimal amounts and dates, which is why "Compare dates, times, and decimals with their module functions", "Decide whether you need a process" and "Treat lists as linked lists" come out clean there, and macro-dsl prescribes `use TinyRouter`, which is why "Unquote each argument once", "Write a function unless the job needs a macro" and "Write module names literally" come out clean there; the rules two or more cases confirm are better evidence. The grading standard lets some shapes pass that a stricter reading would not: in shop-project, a `total/2` that raises `KeyError` on an unpriced SKU counts as clean under the return-tuple rule because its `@doc` calls that a caller bug, and that was the shape of most runs without the skill in every sweep. And the third and fourth sweeps' sessions were shown 16 or 29 skills where the earlier sweeps' sessions were shown 210, so a rule that is a candidate in both and was one before has been clean under both conditions, and a dropped or new row may partly reflect the change. A later sweep that tests these rules should add prompts with room to break them, such as an unpriced SKU the caller can send, dates that compare wrongly as structs, and a list built in a loop.

## Keep prompts neutral

Describe the task only. Do not put the preferences the skill is meant to produce into a prompt (for example "use ETS" or "no comments"). If the prompt asks for them, the run can't tell whether the skill worked.
