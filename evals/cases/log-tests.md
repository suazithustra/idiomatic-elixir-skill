# Log tests

The input is `log-tests-input.ex`, a module that charges a card through a gateway behaviour and logs each outcome with the request id as metadata.

## Prompt

```text
Write ExUnit tests for the `Payments.Charger` module at <evals>/log-tests-input.ex. Cover the three gateway outcomes. Check that a declined card logs a warning whose metadata carries the request id and the amount, that an unavailable gateway logs at error level, and that a successful charge logs nothing at warning level or above.

Write the tests to <output>/charger_test.exs. The file must start ExUnit itself, so that `elixir -r <evals>/log-tests-input.ex <output>/charger_test.exs` runs it (Elixir <elixir-version> is installed; no Mix project and no Hex packages are available). Reply with just the file path when done.
```

## What to check

- Log output is captured with `ExUnit.CaptureLog.capture_log/2` or `with_log/2`, not with a handler added through `:logger.add_handler/3`, a `StringIO` device, or a custom backend.
- The metadata assertions pass a `:metadata` or `:format` option to `capture_log`, so the request id and the amount appear in the captured text; nothing reads handler internals.
- The module runs `async: true`, with no `Logger.configure/1`, `Process.register/2` on the test pid, or application-environment lookup.
- The gateway is replaced through the `Payments.Gateway` behaviour (a test module per outcome, or one that answers by token), not by patching modules at runtime.
- The success test asserts the absence of warning-level output on the captured text, such as `refute log =~ "[warning]"` or an empty `capture_log([level: :warning], ...)`, not with `Process.sleep/1`.
- Assertions use patterns (`assert {:error, :declined} = ...`) with `assert` in front of every match, or `==` with the call under test on the left.
- Tests are grouped in `describe` blocks named after `charge/3` or a condition the block's tests share, and named by what the call did or logged, not by `returns :ok`.
- Every call to `charge/3` runs inside a capture, so the suite prints no log line.
- Only public functions are tested.
- The file passes `mix format --check-formatted` and the tests pass.
- Expected reads: `testing.md`.

## Seen so far
