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

1. Copy the prompt from the case file. Replace `<output>` with a path in a scratch folder outside this repository, `<evals>` with a folder in that scratch space that holds only the case's input files from `cases/` (`code-review-input.ex`, `test-writing-input.ex`, or a fresh copy of `shop-project/`), `<skill>` with the path of the `idiomatic-elixir/` folder, and `<elixir-version>` with the installed version from `elixir --version`. Start the session with that scratch folder as its working directory, so the run cannot read the skill, this folder, or the "What to check" lists.
2. For every run, make sure the skill is not installed in any skills directory the session reads: move the folder or symlink out of the skills folder for the sweep and restore it after. Renaming it inside that folder is not enough, since every entry there is listed to the session as a skill under whatever name it has. A with-skill run must load only the copy the prompt names. For a run without the skill (baseline), add this line to the end of the prompt: `Do not invoke any skills.`
3. For a run with the skill, add this line to the start of the prompt: `First read the skill at <skill>/SKILL.md and follow it, including reading any reference file it points you to for this task.`
4. Run each prompt in a fresh session with no shared context. Smaller, faster models show the most problems. Run those at least twice, because results vary between runs. Keep each session's transcript; the next step searches it.

   A full sweep runs every case once on Opus, twice on Haiku and twice on Sonnet, without the skill first and then with it, and records every run. The scripts under `tools/` are the procedure of record (`tools/README.md` has the commands): `tools/sweep.py` runs the matrix, or a subset of cases and conditions, five sessions at a time, and `tools/run.py` runs one case in one condition. Both start each run as the sweep of 2026-10-21 did: a non-interactive session (`claude -p`, prompt on standard input) whose working directory is its own folder under a scratch root outside this repository, holding only the case's input files, with a copy of the skill folder granted read access for with-skill runs, and shell commands pre-approved only when they start with `mix`, `elixir` or `elixirc`; a non-interactive session cannot answer a permission prompt, so in that sweep a few compound commands (ones with shell variables, `find -exec`, `rm`, or a `python3` heredoc) were refused, which the shop-project records note. A run refuses to start while the skill is installed in the session's skills folder, whatever its condition. Models are passed by identifier (`claude-opus-5-5`, `claude-haiku-5-5`, `claude-sonnet-5-5`); a run whose identifier the command line refuses is retried with the tier's alias and fails if its transcript reports another identifier. Each run's outputs, prompt and transcript are kept under `sweeps/<date>/<case>/<condition>-<tier>-<n>/` (the transcript gzipped) with a `result.json` whose fields `tools/README.md` lists under "What a run records". The gradings go under `sweeps/<date>/grades/`, one file per case and condition written from `tools/grader-brief.md` against the case's checks and the rule index one case at a time; `tools/records.py` then writes the record lines of the next section, and `tools/aggregate.py` folds the gradings into the index column, the violating-run counts and the cull lists, refusing when a grading lacks a verdict for a rule the index lists for its case.
5. Check the output against the case's "What to check" list, including its "Expected reads" line (see below). For a single-file case, run `mix format --check-formatted <output>/<file>.ex`, and compile with `elixir <output>/<file>.ex` where the case allows. For code-review, copy the improved module out of `review.md` into a `.ex` file first and run only the format check; the module does not compile on its own.

Step 3 tests whether agents follow the rules once they read them. It does not test whether an agent loads the skill by itself. To test that, install the skill and give the prompt without the extra line in a fresh session.

Each case ends with an "Expected reads" line naming the reference files a run should read for that task. To see which reference files a run read, search its transcript for a phrase that appears only in that file. Update these if the headings change.

| File | Phrase |
| --- | --- |
| `processes.md` | `Pick the abstraction that matches the job` |
| `library-design.md` | `Take configuration as arguments` |
| `ecto-phoenix.md` | `Keep migrations to schema changes` |
| `macros.md` | `Unquote each argument once` |
| `testing.md` | `Wait for messages, not for time` |

Once per release, also run each case with the skill installed and without the line from step 3, to check that the agent loads the skill and the expected reference files by itself.

## Recording a run

Add one line per run, or per group of identical runs, under the case's "Seen so far", in this shape:

- `YYYY-MM-DD, <short hash>, <model identifier>, with skill or without skill, N runs: what happened, naming the rule that was broken or followed.`

The hash is the committed revision the skill was loaded from, with no uncommitted changes under `idiomatic-elixir/` or `evals/`. The model identifier is the exact name the session reports in its transcript, not the alias used to start it. Keep each transcript next to its outputs under `sweeps/<date>/`, gzipped, so the "Expected reads" phrases can be searched again later with `zgrep`. Notes written before this shape existed stay under the lead "Before 2026-10-21, undated:".

### Between sweeps

A rule has improved between two sweeps when its violating with-skill runs, counted across every case that exercises it, fell by at least two; a drop of one run is inside the variation above and is reported as unchanged. A rule that was clean with the skill has regressed when it has two or more violating with-skill runs in the later sweep; one run is recorded in the case file and not counted. When a rule's text changed between the sweeps, count each of its sentences on its own: a sentence the rewording allows no longer counts, and the sentences that remain carry the comparison. For a sentence the earlier sweep graded only in `other_violations`, that free text supplies its earlier count. `tools/aggregate.py --previous` prints these counts over the cases both sweeps graded for the rule, and says when the case sets differ; a count for a sentence the earlier sweep recorded only in `other_violations` is added by hand.

When a case is added to a rule's index row after a sweep was graded, that sweep's grades carry no verdict for the pair; `tools/aggregate.py` leaves the case out of that row and prints a note, and refuses only when some runs of a case have the verdict and others do not.

A check batch, which reruns one case with the skill (Haiku twice, Sonnet twice) while a rule is being reworded, lives under `sweeps/<date>-check/` in the same layout as a sweep, with one grades file per case; a batch rerun after a further rewording lives under `sweeps/<date>-check-2/`. Check batches get no record lines; the next sweep's lines supersede them. In the check batches of 2026-10-21 the one-step `with` sentence passed in webhook-parser, rate-limiter and shop-project but stayed at 2 of 4 runs in order-report after two rewordings, and the second sweep kept it at 2 of 5 there. A third rewording after that sweep, which names the public-function shape those runs wrote and shows it as the rule's example, passed 0 of 4 in the batch under `sweeps/2026-10-22-check/`; the same batch graded the pin and whole-value forms added to "Assert with patterns" at 0 of 4 in test-writing, and the captures rule, now allowing `&2` for one operator or call and naming `&3` as the limit, at 0 of 4 in order-report, where the three rules reworded in the previous round also held at 0 of 4.

The "Without skill" column holds the latest sweep; an earlier sweep's values stay in its `grades/` folder. After a second sweep, a candidate is confirmed when every tier was clean without the skill in both sweeps, dropped when any tier violated the rule without the skill in the second, and unconfirmed when a tier was unavailable or never produced the construct in the second; the cull section lists all three.

Tiers are named by model identifier, the exact name the transcript reports. A run starts with that identifier and falls back to the tier's alias only when the command line refuses it; a transcript that names another model fails the run, and a tier with no accepted route is unavailable, which leaves its rows unconfirmed.

## Which case exercises which rule

A rule with no case can regress unnoticed. The rule cell is the rule's exact heading, which `check_skill.exs` matches against the skill; rows follow `SKILL.md`, then the reference files in alphabetical order. The cases cell names the cases that check the rule, or starts with "not provocable:" and says why no neutral prompt can. The "Without skill" cell is filled from the sweep: for each tier, violated, clean, not exercised, or unavailable.

| Rule | Cases | Without skill |
| --- | --- | --- |
| Read required keys with `map.key` or a pattern; keep `map[:key]` for optional keys | code-review, webhook-parser | Opus violated, Haiku violated, Sonnet clean |
| Match every expected shape and let unexpected ones crash | code-review, webhook-parser | Opus violated, Haiku violated, Sonnet violated |
| In multi-clause functions, bind in the head only what patterns and guards use | webhook-parser | Opus clean, Haiku clean, Sonnet clean |
| Update structs with `%{struct \| field: value}` | shop-project | Opus clean, Haiku clean, Sonnet clean |
| Convert external strings to atoms with explicit clauses | webhook-parser, order-report, shop-project, code-review | Opus clean, Haiku clean, Sonnet clean |
| Branch with function clauses and guards before reaching for `if` or `cond` | rate-limiter, code-review | Opus violated, Haiku violated, Sonnet violated |
| Chain fallible steps with `with`; normalize each step's error in a small private function | webhook-parser, shop-project, rate-limiter, order-report | Opus violated, Haiku violated, Sonnet violated |
| Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs | webhook-parser, library-client, shop-project, code-review | Opus clean, Haiku clean, Sonnet clean |
| Use `and`, `or`, `not` when the operands are booleans | code-review | Opus violated, Haiku violated, Sonnet violated |
| Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it | code-review | Opus clean, Haiku clean, Sonnet clean |
| Use the `Enum` or `Map` function made for the job | order-report | Opus violated, Haiku violated, Sonnet violated |
| Treat lists as linked lists | order-report | Opus clean, Haiku clean, Sonnet clean |
| Compare dates, times, and decimals with their module functions | order-report | Opus clean, Haiku clean, Sonnet clean |
| Store and compute money as integer minor units or `Decimal`, never floats | order-report, shop-project | Opus clean, Haiku clean, Sonnet clean |
| Parse external data into structs where it enters the system | webhook-parser | Opus clean, Haiku clean, Sonnet violated |
| Use one atom-valued field or option instead of overlapping booleans | code-review | Opus clean, Haiku violated, Sonnet violated |
| Group related parameters | library-client | Opus clean, Haiku violated, Sonnet violated |
| Give each function one return shape | library-client, code-review | Opus clean, Haiku violated, Sonnet clean |
| Read configuration at runtime, not into module attributes | library-client | Opus clean, Haiku clean, Sonnet clean |
| Naming | rate-limiter, webhook-parser, order-report, shop-project | Opus clean, Haiku violated, Sonnet violated |
| Comments explain why; documentation goes in `@moduledoc` and `@doc` | code-review, webhook-parser, rate-limiter | Opus violated, Haiku violated, Sonnet violated |
| Keep functions short and at one level of detail | code-review | Opus violated, Haiku violated, Sonnet violated |
| Write pipelines that start with a value and read top to bottom | code-review | Opus violated, Haiku violated, Sonnet violated |
| Use captures for one-call lambdas and `fn` for anything longer | order-report | Opus clean, Haiku clean, Sonnet violated |
| Before you finish | shop-project | Opus clean, Haiku violated, Sonnet violated |
| Validate input with changesets | ecto-phoenix, code-review; the accessor sentence is not provocable: no prompt needs to know whether a field changed | Opus violated, Haiku violated, Sonnet violated |
| Let Phoenix turn missing records into 404 responses | ecto-phoenix | Opus clean, Haiku clean, Sonnet clean |
| Group writes that must succeed together | ecto-phoenix | Opus clean, Haiku clean, Sonnet clean |
| Load associations up front | ecto-phoenix | Opus clean, Haiku clean, Sonnet clean |
| Keep migrations to schema changes | ecto-phoenix | Opus violated, Haiku violated, Sonnet violated |
| Keep database access in contexts | ecto-phoenix | Opus clean, Haiku clean, Sonnet clean |
| Take configuration as arguments, not from the application environment | library-client | Opus clean, Haiku violated, Sonnet violated |
| Use exception structs as error reasons | library-client | Opus clean, Haiku violated, Sonnet clean |
| Make polymorphism explicit | library-client | Opus clean, Haiku violated, Sonnet violated |
| Add specs, and hide technical functions from the docs | library-client, macro-dsl | Opus violated, Haiku violated, Sonnet violated |
| Keep secrets out of logs and inspect output | library-client | Opus clean, Haiku not exercised, Sonnet violated |
| Keep structs under 32 fields | not provocable: no prompt builds a struct with that many fields | not provocable |
| Write a function unless the job needs a macro | macro-dsl | Opus clean, Haiku clean, Sonnet clean |
| Keep `quote` blocks small | macro-dsl | Opus clean, Haiku violated, Sonnet violated |
| Unquote each argument once | macro-dsl | Opus clean, Haiku clean, Sonnet clean |
| Offer `import` or `alias` instead of `use` when they are enough | macro-dsl; the import-instead-of-use sentence is not provocable: the prompt prescribes `use TinyRouter` | Opus violated, Haiku violated, Sonnet violated |
| Avoid compile-time dependencies on modules used only at runtime | macro-dsl | Opus clean, Haiku violated, Sonnet violated |
| Write module names literally | macro-dsl | Opus clean, Haiku clean, Sonnet clean |
| Decide whether you need a process | order-report | Opus clean, Haiku clean, Sonnet clean |
| Pick the abstraction that matches the job | rate-limiter; the timeout sentence is not provocable: no prompt maps concurrently | Opus clean, Haiku violated, Sonnet violated |
| Keep each process behind one module | rate-limiter | Opus clean, Haiku clean, Sonnet clean |
| Write GenServers that stay responsive | rate-limiter | Opus violated, Haiku violated, Sonnet clean |
| Use ETS for data many processes read | rate-limiter | Opus clean, Haiku violated, Sonnet violated |
| Supervise every long-lived process | rate-limiter, code-review | Opus clean, Haiku violated, Sonnet clean |
| Send processes only the data they need | code-review | Opus violated, Haiku violated, Sonnet violated |
| Run tests concurrently unless they share global state | test-writing | Opus clean, Haiku violated, Sonnet violated |
| Group tests by function and name them by behaviour | test-writing | Opus violated, Haiku violated, Sonnet violated |
| Assert with patterns | test-writing | Opus clean, Haiku clean, Sonnet violated |
| Wait for messages, not for time | test-writing | Opus violated, Haiku violated, Sonnet violated |
| Start processes with `start_supervised!/1` | test-writing | Opus clean, Haiku violated, Sonnet violated |
| Replace dependencies at boundaries, through behaviours | test-writing | Opus clean, Haiku clean, Sonnet clean |
| Use setup for shared data | test-writing | Opus clean, Haiku clean, Sonnet clean |

## Cull candidates

A rule every tier followed without the skill is a candidate for deletion, not a deletion: with five runs per case, a rule broken in a third of runs shows clean about one time in six. Delete a rule only after a second sweep, on a later date, agrees. The lists below compare the sweep of 2026-10-22 at db91c23, kept under `sweeps/2026-10-22/`, with the sweep of 2026-10-21 at 93873be, kept under `sweeps/2026-10-21/`; every tier was available in both. A rule is confirmed when every tier was clean without the skill in both sweeps, dropped when a tier violated it without the skill in the second, and unconfirmed when a tier was unavailable or never produced the construct in the second. The dropped `with` and `Enum`/`Map` rows are a change of text, not of behaviour: their rewordings name shapes (a one-step `with`, a per-key fold) that the first sweep's grading did not count, and the second sweep graded the `with` rule in three cases the first did not list it for.

Confirmed (a candidate in both sweeps):
- Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it: Opus 1 run, Haiku 2, Sonnet 2 in code-review
- Compare dates, times, and decimals with their module functions: Opus 1 run, Haiku 2, Sonnet 2 in order-report
- Convert external strings to atoms with explicit clauses: Opus 1 run, Haiku 2, Sonnet 2 in code-review, order-report, shop-project, webhook-parser
- Decide whether you need a process: Opus 1 run, Haiku 2, Sonnet 2 in order-report
- Group writes that must succeed together: Opus 1 run, Haiku 2, Sonnet 2 in ecto-phoenix
- Keep database access in contexts: Opus 1 run, Haiku 2, Sonnet 2 in ecto-phoenix
- Let Phoenix turn missing records into 404 responses: Opus 1 run, Haiku 2, Sonnet 2 in ecto-phoenix
- Load associations up front: Opus 1 run, Haiku 2, Sonnet 2 in ecto-phoenix
- Read configuration at runtime, not into module attributes: Opus 1 run, Haiku 2, Sonnet 2 in library-client
- Replace dependencies at boundaries, through behaviours: Opus 1 run, Haiku 2, Sonnet 2 in test-writing
- Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs: Opus 1 run, Haiku 2, Sonnet 2 in code-review, library-client, shop-project, webhook-parser
- Store and compute money as integer minor units or `Decimal`, never floats: Opus 1 run, Haiku 2, Sonnet 2 in order-report, shop-project
- Treat lists as linked lists: Opus 1 run, Haiku 2, Sonnet 2 in order-report
- Unquote each argument once: Opus 1 run, Haiku 2, Sonnet 2 in macro-dsl
- Update structs with `%{struct | field: value}`: Opus 1 run, Haiku 2, Sonnet 2 in shop-project
- Use setup for shared data: Opus 1 run, Haiku 2, Sonnet 2 in test-writing
- Write a function unless the job needs a macro: Opus 1 run, Haiku 2, Sonnet 2 in macro-dsl
- Write module names literally: Opus 1 run, Haiku 2, Sonnet 2 in macro-dsl

Dropped (a candidate the previous sweep had, violated in this one):
- Chain fallible steps with `with`; normalize each step's error in a small private function: Opus violated, Haiku violated, Sonnet violated in order-report, rate-limiter, shop-project, webhook-parser
- Use captures for one-call lambdas and `fn` for anything longer: Opus clean, Haiku clean, Sonnet violated in order-report
- Use the `Enum` or `Map` function made for the job: Opus violated, Haiku violated, Sonnet violated in order-report

Unconfirmed (a candidate the previous sweep had; a tier did not exercise it this time):
- none

New candidates (clean in every tier this sweep, not a candidate before):
- In multi-clause functions, bind in the head only what patterns and guards use: Opus 1 run, Haiku 2, Sonnet 2 in webhook-parser
- Keep each process behind one module: Opus 1 run, Haiku 2, Sonnet 2 in rate-limiter

Unconfirmed (a tier never produced the construct the rule governs):
- Keep secrets out of logs and inspect output: Opus clean, Haiku not exercised, Sonnet violated in library-client

### Decision after the second sweep

The 18 confirmed candidates stay in the skill for now. Both sweeps ran Claude models only (`claude-opus-5-5`, `claude-haiku-5-5`, `claude-sonnet-5-5`), and the skill is published for any model, so a rule is deleted only when a sweep on other commonly used models agrees. `tools/run.py` starts `claude -p` sessions; another model needs a runner of its own that leaves the same run folders, so the grading and aggregation steps can stay as they are.

Two cautions apply to the confirmed list even for Claude. Eleven of the 18 rules were exercised by one case, and some of those prompts leave little room to break the rule: order-report hands the model decimal amounts and dates, which is why "Compare dates, times, and decimals with their module functions", "Decide whether you need a process" and "Treat lists as linked lists" come out clean there, and macro-dsl prescribes `use TinyRouter`, which is why "Unquote each argument once", "Write a function unless the job needs a macro" and "Write module names literally" come out clean there. The rules four cases confirm ("Convert external strings to atoms with explicit clauses" and "Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs") are better evidence. And the grading standard lets some shapes pass that a stricter reading would not: in shop-project, a `total/2` that raises `KeyError` on an unpriced SKU counts as clean under the return-tuple rule because its `@doc` calls that a caller bug, and that was the shape of most runs without the skill in both sweeps. A later sweep that tests these rules should add prompts with room to break them, such as an unpriced SKU the caller can send, dates that compare wrongly as structs, and a list built in a loop.

## Keep prompts neutral

Describe the task only. Do not put the preferences the skill is meant to produce into a prompt (for example "use ETS" or "no comments"). If the prompt asks for them, the run can't tell whether the skill worked.
