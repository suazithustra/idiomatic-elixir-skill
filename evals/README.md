# Evals

Fixed test prompts to rerun after changing the skill, to check that rules still work and nothing got worse. Nothing in `SKILL.md` points here, so agents using the skill never load these files.

## Cases

| File | Exercises |
| --- | --- |
| `webhook-parser.md` | external string-keyed input, error tuples, atom conversion |
| `rate-limiter.md` | shared state, processes, ETS, supervision |
| `order-report.md` | collections, decimals, date comparison |
| `library-client.md` | library options and configuration, error types |
| `code-review.md` | reviewing a module with planted problems (`code-review-input.ex`) |
| `shop-project.md` | working inside a Mix project with Credo and tests (`shop-project/`) |

## Running a case

1. Copy the prompt from the case file. Replace `<output>` with a path in a scratch folder, `<evals>` with the path of this folder, and `<skill>` with the path of the `idiomatic-elixir/` folder.
2. For a run without the skill (baseline), add this line to the end of the prompt: `Do not invoke any skills.`
3. For a run with the skill, add this line to the start of the prompt: `First read the skill at <skill>/SKILL.md and follow it, including reading any reference file it points you to for this task.`
4. Run each prompt in a fresh agent session with no shared context. Smaller, faster models show the most problems. Run those at least twice, because results vary between runs.
5. Check the output against the case's "What to check" list. Run `mix format --check-formatted` on the output, and compile it where the case allows.

Step 3 tests whether agents follow the rules once they read them. It does not test whether an agent loads the skill by itself. To test that, install the skill and give the prompt without the extra line in a fresh session.

To see which reference files a run read, search its transcript for a phrase that appears only in that file. Update these if the headings change.

| File | Phrase |
| --- | --- |
| `processes.md` | `Pick the abstraction that matches the job` |
| `library-design.md` | `Take configuration as arguments` |
| `ecto-phoenix.md` | `Keep migrations to schema changes` |
| `macros.md` | `Unquote each argument once` |
| `testing.md` | `Wait for messages, not for time` |

The "Seen so far" notes in each case record runs with Anthropic's Claude Haiku, Sonnet, and Opus models.

## Keep prompts neutral

Describe the task only. Do not put the preferences the skill is meant to produce into a prompt (for example "use ETS" or "no comments"). If the prompt asks for them, the run can't tell whether the skill worked.
