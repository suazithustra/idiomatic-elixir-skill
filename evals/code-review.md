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
| 2, 5, 7, 37 | Comments restate the code; the module and function descriptions belong in `@moduledoc` and `@doc` |
| 8 | `String.to_atom/1` on external input |
| 8 | A missing role raises outside the `try`, unlike every other bad field |
| 10–33 | `try/rescue _ ->` around the whole body; `String.to_integer/1` is used for its exception instead of `Integer.parse/1` |
| 10–33 | `try` contains `if`, which contains `case`, which contains more `if`s |
| 11 | Single-step pipe |
| 14 | `&&` with boolean operands |
| 14 | `is_binary(email)` can never be false, because `String.downcase/1` already raised on non-strings |
| 14 | Magic number `18` |
| 15–17 | Struct inserted without a changeset, so there is no validation or `unique_constraint` |
| 19 | `notify` and `silent` are overlapping booleans; `&&` and `!` with boolean operands |
| 23 | `return_id` changes the return shape |
| 25 | `_ ->` swallows the `{:error, changeset}` from `Repo.insert/1` |
| 29, 32 | Every failure returns the same `{:error, :invalid}` |
| 38 | Unsupervised `spawn/1`; the closure copies the whole `user` struct |
| 42 | `user[:name]` on a struct raises `UndefinedFunctionError` |

## Seen so far

- Without the skill: Opus found nearly everything but missed the `&&`. Haiku missed the `&&` and its improved code still called `String.to_atom/1`.
- With the skill: Haiku and Sonnet reported the `&&`, the overlapping options, and the comments that belong in `@doc`. In the latest round, all three runs reported the `spawn` and fixed it with `Task.Supervisor`. One earlier Haiku run reported the `spawn` but left it in its improved code.
