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

## Running a case

1. Copy the prompt from the case file. Replace `<output>` with a path in a scratch folder, `<evals>` with the path of this folder, `<skill>` with the path of the `idiomatic-elixir/` folder, and `<elixir-version>` with the installed version from `elixir --version`.
2. For a run without the skill (baseline), add this line to the end of the prompt: `Do not invoke any skills.`
3. For a run with the skill, add this line to the start of the prompt: `First read the skill at <skill>/SKILL.md and follow it, including reading any reference file it points you to for this task.`
4. Run each prompt in a fresh agent session with no shared context. Smaller, faster models show the most problems. Run those at least twice, because results vary between runs.
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

The "Seen so far" notes in each case record runs with Anthropic's Claude Haiku, Sonnet, and Opus models.

Once per release, also run each case with the skill installed and without the line from step 3, to check that the agent loads the skill and the expected reference files by itself.

## Which case exercises which rule

A rule with no case can regress unnoticed. Add a check to a case when you add a rule.

| Rule | Cases |
| --- | --- |
| Read required keys with `map.key` or a pattern | code-review, webhook-parser |
| Match every expected shape and let unexpected ones crash | code-review, webhook-parser |
| In multi-clause functions, bind in the head only what patterns and guards use | none yet |
| Update structs with `%{struct \| field: value}` | shop-project |
| Convert external strings to atoms with explicit clauses | webhook-parser, order-report, shop-project, code-review |
| Branch with function clauses and guards before `if` or `cond` | rate-limiter, code-review |
| Chain fallible steps with `with` | webhook-parser |
| Return `{:ok, value}` or `{:error, reason}`; raise only for bugs | webhook-parser, library-client, shop-project, code-review |
| Use `and`, `or`, `not` when the operands are booleans | code-review |
| Assign the result of `if`, `case`, and `Enum` calls | none yet |
| Use the `Enum` or `Map` function made for the job | order-report |
| Treat lists as linked lists | order-report |
| Compare dates, times, and decimals with their module functions | order-report |
| Store and compute money as integer minor units or `Decimal` | order-report, shop-project |
| Parse external data into structs where it enters the system | webhook-parser |
| Use one atom-valued field or option instead of overlapping booleans | code-review |
| Group related parameters | library-client |
| Give each function one return shape | library-client, code-review |
| Read configuration at runtime, not into module attributes | library-client |
| Naming | rate-limiter, webhook-parser, order-report, shop-project |
| Comments explain why; documentation goes in `@moduledoc` and `@doc` | code-review, webhook-parser, rate-limiter |
| Keep functions short and at one level of detail | code-review |
| Write pipelines that start with a value and read top to bottom | code-review |
| Use captures for one-call lambdas | none yet |
| Before you finish | shop-project |
| `processes.md` | rate-limiter, test-writing, code-review |
| `library-design.md` | library-client, macro-dsl |
| `macros.md` | macro-dsl |
| `testing.md` | test-writing, shop-project |
| `ecto-phoenix.md` | ecto-phoenix, code-review |

## Keep prompts neutral

Describe the task only. Do not put the preferences the skill is meant to produce into a prompt (for example "use ETS" or "no comments"). If the prompt asks for them, the run can't tell whether the skill worked.
