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

- Not yet run.
