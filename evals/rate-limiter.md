# Rate limiter

## Prompt

```text
Write a per-user rate limiter for an Elixir/Phoenix application: each user may make at most N requests per rolling minute. Controllers and background jobs in several parts of the app need to check it before doing work. Include how it is started and an example of a caller.

Write all the code to <output>/ratelimit.ex. You may use the shell to check it compiles (Elixir 1.20 is installed; Phoenix is not, so caller examples can't compile). Reply with just the file path when done.
```

## What to check

- Shared state lives in a supervised process, or in an ETS table owned by one, started from the supervision tree.
- If callers read and write ETS directly, there is no read-then-write race: only atomic operations, or insert-then-count.
- Per-user state has a way to be removed, such as a periodic sweep.
- Modules are under the application namespace (`MyApp.RateLimiter`, not `RateLimiter`).
- `start_link/1` accepts a `:name` option so tests can start their own instance.
- Boolean results are branched on with `if`, not `case ... true -> ... false ->`.
- No comments that restate the code.
- The file passes `mix format --check-formatted`.

## Seen so far

- Without the skill: Sonnet sent every check through one GenServer. Haiku used a top-level module name, never removed old users, and wrote comments that restate the code.
- With the skill: one Haiku run read from ETS and wrote back in the caller, which is a race; `processes.md` was changed to cover it. Later runs followed the process rules. Haiku still wrote some comments that restate the code and never ran `mix format`.
