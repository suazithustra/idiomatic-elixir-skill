# Test writing

The input is `test-writing-input.ex`, a GenServer that notifies subscribers and sends email through a behaviour.

## Prompt

```text
Write ExUnit tests for the `Notify.Subscriptions` module at <evals>/test-writing-input.ex. Cover subscribing, publishing to process and email subscribers, listing subscribers, and what happens when a subscribed process exits.

Write the tests to <output>/subscriptions_test.exs. The file must start ExUnit itself, so that `elixir -r <evals>/test-writing-input.ex <output>/subscriptions_test.exs` runs it (Elixir <elixir-version> is installed; no Mix project and no Hex packages are available). Reply with just the file path when done.
```

## What to check

- The test module uses `async: true`.
- Each test starts its own server with `start_supervised!/1` and a test-specific `:name`, or no name.
- The mailer is replaced through the `Notify.Mailer` behaviour (a test module that implements it, or a mock built on it), not by redefining `Notify.Mailer` or patching modules at runtime.
- Notifications are awaited with `assert_receive` and `refute_receive`. There is no `Process.sleep/1`.
- The exit test monitors the process and waits for the `:DOWN` message, or calls `:sys.get_state/1`, before asserting that the subscriber is gone. There is no polling of `Process.alive?/1`.
- Assertions use patterns (`assert [^pid] = ...`, `assert_receive {:notification, "news", %{id: 1}}`), not `elem/2` or `==` on a tuple's parts.
- Tests are grouped in `describe` blocks per function and named by behaviour.
- Shared setup returns a map that tests match in their heads.
- Only public functions are tested.
- The file passes `mix format --check-formatted` and the tests pass.
- Expected reads: `testing.md` and `processes.md`.

## Seen so far

- 2026-10-21, 93873be, claude-opus-5-5, without skill, 1 run: Uses a behaviour-based mailer, start_supervised!/1 with per-test names, assert_receive with a :DOWN monitor, async: true and setup maps; broke the grouping rule (two describe blocks not named after a function) and, in one test, started the server under the default global name in an async module.
- 2026-10-21, 93873be, claude-haiku-5-5, without skill, 1 run: Uses a behaviour-based mailer, start_supervised!/1 with unique names and setup maps, but runs async: false because of its own registered test process, polls with Process.sleep after exits, groups exit tests under a non-function describe, and is not formatted.
- 2026-10-21, 93873be, claude-haiku-5-5, without skill, 1 run: Uses a behaviour-based mailer, start_supervised!/1 with unique names and setup maps, but runs async: false because of its own registered test process, polls with Process.sleep after exits, groups exit tests under a non-function describe, and has one unformatted line.
- 2026-10-21, 93873be, claude-sonnet-5-5, without skill, 1 run: Uses a behaviour-based mailer and setup maps, but runs async: false because it routes the test pid through the application env, polls with Process.sleep (mostly without a :DOWN monitor), calls start_link directly once, asserts is_pid once, and names some tests only by their :ok return.
- 2026-10-21, 93873be, claude-sonnet-5-5, without skill, 1 run: Uses a behaviour-based mailer and setup maps, but runs async: false because it routes the test pid through the application env, polls with Process.sleep (mostly without a :DOWN monitor), calls start_link directly once, and groups exit tests under a non-function describe.
- 2026-10-21, 93873be, claude-opus-5-5, with skill, 1 run: Uses async: true, start_supervised!/1 with per-test names, a behaviour-based mailer routed through a Registry, :DOWN monitors and a sync call before refute_received, and setup maps; broke only the grouping rule with one describe block not named after a function; read SKILL.md, testing.md and processes.md.
- 2026-10-21, 93873be, claude-haiku-5-5, with skill, 1 run: Uses a behaviour-based mailer, start_supervised!/1 with unique names, :DOWN monitors and setup maps, but moves the email tests into an async: false module because of its own registered test process and groups exit tests under non-function describe blocks; read SKILL.md and testing.md, not processes.md.
- 2026-10-21, 93873be, claude-haiku-5-5, with skill, 1 run: Uses a behaviour-based mailer, :DOWN monitors and setup maps, but runs async: false because of its own registered test process, calls start_link directly twice (once under the default global name), and groups exit tests under a non-function describe; read SKILL.md and testing.md, not processes.md.
- 2026-10-21, 93873be, claude-sonnet-5-5, with skill, 1 run: Uses async: true with a Registry-based behaviour mailer, unique server names, :DOWN monitors and setup maps, but calls start_link directly once, groups exit tests under a non-function describe, names one test only by its :ok return, and pipes a single step from a function call; read SKILL.md, testing.md and processes.md.
- 2026-10-21, 93873be, claude-sonnet-5-5, with skill, 1 run: Uses a behaviour-based mailer, start_supervised!/1 with per-test names, :DOWN monitors, :sys.get_state before refutes and pattern assertions, but runs async: false because it routes the test pid through the application env, groups exit tests under a non-function describe, and extracts a name with a single-step pipe into elem/2; read SKILL.md, testing.md and processes.md.
