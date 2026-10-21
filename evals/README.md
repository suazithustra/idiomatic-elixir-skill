# Evals

Fixed test prompts to rerun after changing the skill, to check that rules still work and nothing got worse. Nothing in `SKILL.md` points here, so agents using the skill never load these files.

## Cases

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

1. Copy the prompt from the case file. Replace `<output>` with a path in a scratch folder outside this repository, `<evals>` with a folder in that scratch space that holds only the case's input files (`code-review-input.ex`, `test-writing-input.ex`, or a fresh copy of `shop-project/`), `<skill>` with the path of the `idiomatic-elixir/` folder, and `<elixir-version>` with the installed version from `elixir --version`. Start the session with that scratch folder as its working directory, so the run cannot read the skill, this folder, or the "What to check" lists.
2. For a run without the skill (baseline), make sure the skill is not installed in any skills directory the session reads (move the folder or symlink aside for the run and restore it after), and add this line to the end of the prompt: `Do not invoke any skills.`
3. For a run with the skill, add this line to the start of the prompt: `First read the skill at <skill>/SKILL.md and follow it, including reading any reference file it points you to for this task.`
4. Run each prompt in a fresh session with no shared context. Smaller, faster models show the most problems. Run those at least twice, because results vary between runs. Keep each session's transcript; the next step searches it.
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

The hash is the committed revision the skill was loaded from, with no uncommitted changes under `idiomatic-elixir/` or `evals/`. The model identifier is the exact name the session reports in its transcript, not the alias used to start it. Keep each transcript's path with your own notes so the "Expected reads" phrases can be searched again later. Notes written before this shape existed stay under the lead "Before 2026-10-21, undated:".

## Which case exercises which rule

A rule with no case can regress unnoticed. The rule cell is the rule's exact heading, which `check_skill.exs` matches against the skill; rows follow `SKILL.md`, then the reference files in alphabetical order. The cases cell names the cases that check the rule, or starts with "not provocable:" and says why no neutral prompt can. The "Without skill" cell is filled from the sweep: for each tier, violated, clean, not exercised, or unavailable.

| Rule | Cases | Without skill |
| --- | --- | --- |
| Read required keys with `map.key` or a pattern; keep `map[:key]` for optional keys | code-review, webhook-parser | |
| Match every expected shape and let unexpected ones crash | code-review, webhook-parser | |
| In multi-clause functions, bind in the head only what patterns and guards use | webhook-parser | |
| Update structs with `%{struct \| field: value}` | shop-project | |
| Convert external strings to atoms with explicit clauses | webhook-parser, order-report, shop-project, code-review | |
| Branch with function clauses and guards before reaching for `if` or `cond` | rate-limiter, code-review | |
| Chain fallible steps with `with`; normalize each step's error in a small private function | webhook-parser | |
| Return `{:ok, value}` or `{:error, reason}` for expected failures; raise only for bugs | webhook-parser, library-client, shop-project, code-review | |
| Use `and`, `or`, `not` when the operands are booleans | code-review | |
| Assign the result of `if`, `case`, and `Enum` calls; rebinding inside a block does not escape it | code-review | |
| Use the `Enum` or `Map` function made for the job | order-report | |
| Treat lists as linked lists | order-report | |
| Compare dates, times, and decimals with their module functions | order-report | |
| Store and compute money as integer minor units or `Decimal`, never floats | order-report, shop-project | |
| Parse external data into structs where it enters the system | webhook-parser | |
| Use one atom-valued field or option instead of overlapping booleans | code-review | |
| Group related parameters | library-client | |
| Give each function one return shape | library-client, code-review | |
| Read configuration at runtime, not into module attributes | library-client | |
| Naming | rate-limiter, webhook-parser, order-report, shop-project | |
| Comments explain why; documentation goes in `@moduledoc` and `@doc` | code-review, webhook-parser, rate-limiter | |
| Keep functions short and at one level of detail | code-review | |
| Write pipelines that start with a value and read top to bottom | code-review | |
| Use captures for one-call lambdas and `fn` for anything longer | order-report | |
| Before you finish | shop-project | |
| Validate input with changesets | ecto-phoenix, code-review; the accessor sentence is not provocable: no prompt needs to know whether a field changed | |
| Let Phoenix turn missing records into 404 responses | ecto-phoenix | |
| Group writes that must succeed together | ecto-phoenix | |
| Load associations up front | ecto-phoenix | |
| Keep migrations to schema changes | ecto-phoenix | |
| Keep database access in contexts | ecto-phoenix | |
| Take configuration as arguments, not from the application environment | library-client | |
| Use exception structs as error reasons | library-client | |
| Make polymorphism explicit | library-client | |
| Add specs, and hide technical functions from the docs | library-client, macro-dsl | |
| Keep secrets out of logs and inspect output | library-client | |
| Keep structs under 32 fields | not provocable: no prompt builds a struct with that many fields | |
| Write a function unless the job needs a macro | macro-dsl | |
| Keep `quote` blocks small | macro-dsl | |
| Unquote each argument once | macro-dsl | |
| Offer `import` or `alias` instead of `use` when they are enough | not provocable: the macro-dsl prompt prescribes `use TinyRouter` | |
| Avoid compile-time dependencies on modules used only at runtime | not provocable: no prompt has a second module to depend on | |
| Write module names literally | macro-dsl | |
| Decide whether you need a process | order-report | |
| Pick the abstraction that matches the job | rate-limiter; the timeout sentence is not provocable: no prompt maps concurrently | |
| Keep each process behind one module | rate-limiter | |
| Write GenServers that stay responsive | rate-limiter | |
| Use ETS for data many processes read | rate-limiter | |
| Supervise every long-lived process | rate-limiter, code-review | |
| Send processes only the data they need | code-review | |
| Run tests concurrently unless they share global state | test-writing | |
| Group tests by function and name them by behaviour | test-writing | |
| Assert with patterns | test-writing | |
| Wait for messages, not for time | test-writing | |
| Start processes with `start_supervised!/1` | test-writing | |
| Replace dependencies at boundaries, through behaviours | test-writing | |
| Use setup for shared data | test-writing | |

## Keep prompts neutral

Describe the task only. Do not put the preferences the skill is meant to produce into a prompt (for example "use ETS" or "no comments"). If the prompt asks for them, the run can't tell whether the skill worked.
