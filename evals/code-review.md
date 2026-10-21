# Code review

The input is `code-review-input.ex`, a module with planted problems.

## Prompt

```text
Review the Elixir module at <evals>/code-review-input.ex and write an improved version.

Write your review (a list of findings) and the improved code to <output>/review.md. Reply with just the file path when done.
```

## What to check

Count how many planted problems the review reports. The improved code must fix every problem the review reports.

| Line | Problem |
| --- | --- |
| 2, 5, 7, 39 | Comments restate the code; the module and function descriptions belong in `@moduledoc` and `@doc` |
| 8 | `String.to_atom/1` on external input |
| 8 | A missing role raises outside the `try`, unlike every other bad field |
| 10–35 | `try/rescue _ ->` around the whole body; `String.to_integer/1` is used for its exception instead of `Integer.parse/1` |
| 10–35 | `try` contains `if`, which contains `case`, which contains more `if`s |
| 12 | Single-step pipe |
| 16 | `&&` with boolean operands |
| 16 | `is_binary(email)` can never be false, because `String.downcase/1` already raised on non-strings |
| 16 | Magic number `18` |
| 17–19 | Struct inserted without a changeset, so there is no validation or `unique_constraint` |
| 21 | `notify` and `silent` are overlapping booleans |
| 25 | `return_id` changes the return shape |
| 27 | `_ ->` swallows the `{:error, changeset}` from `Repo.insert/1` |
| 31, 34 | Every failure returns the same `{:error, :invalid}` |
| 40 | Unsupervised `spawn/1`; the closure copies the whole `user` struct |
| 44 | `user[:name]` on a struct raises `UndefinedFunctionError` |
| 46 | Pipe into an anonymous function, which is also a single-step pipe |

Must not report (correct code a rule could be misapplied to):

| Line | Why it is fine |
| --- | --- |
| 11 | The comment explains a reason the code cannot show, so it stays |
| 14 | `"nickname"` is an optional key, so `params["nickname"]` and `\|\|` with a default are the right tools |
| 21 | `opts[:notify]` and `opts[:silent]` can be `nil`, so `&&` and `!` are right there; the overlapping options are the problem, not the operators |

Also check:

- Each finding names the rule it applies and quotes the line.
- The improved code still returns normally for `import_user(params)` with no options (no `and` or `not` on a `nil` option).
- Expected reads: `processes.md` (the `spawn`) and `ecto-phoenix.md` (the insert).

## Seen so far

- Without the skill: Opus found nearly everything but missed the `&&`. Haiku missed the `&&` and its improved code still called `String.to_atom/1`.
- With the skill: Haiku and Sonnet reported the `&&`, the overlapping options, and the comments that belong in `@doc`. In the latest round, all three runs reported the `spawn` and fixed it with `Task.Supervisor`. One earlier Haiku run reported the `spawn` but left it in its improved code.
