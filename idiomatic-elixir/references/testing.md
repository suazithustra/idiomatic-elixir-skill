# ExUnit tests

## Run tests concurrently unless they share global state

Start test modules with `use ExUnit.Case, async: true`. Use `async: false` only when the tests touch global state that cannot be isolated, such as the application environment, named singleton processes, or global mocks. With Ecto, the SQL sandbox lets database tests run with `async: true`.

## Group tests by function and name them by behaviour

```elixir
describe "parse/1" do
  test "returns a refund for refund.created events" do
    # ...
  end

  test "returns an error for unknown event types" do
    # ...
  end
end
```

## Assert with patterns

A pattern asserts the shape and binds values for further checks, without repeating fields the test does not care about. Use `==` when the whole value matters.

```elixir
# Instead of
{:ok, user} = Accounts.create_user(attrs)
assert user.email == "a@example.com"
assert user.role == :member
# write
assert {:ok, %User{email: "a@example.com", role: :member}} = Accounts.create_user(attrs)

# Instead of
assert elem(result, 0) == :error
# write
assert {:error, {:missing_field, "amount"}} = Webhook.parse(payload)
```

## Wait for messages, not for time

Do not use `Process.sleep/1` to wait for asynchronous work. Make the work send a message, or observe it, and use `assert_receive` and `refute_receive`, which return as soon as the message arrives.

```elixir
test "notifies subscribers" do
  Notifier.subscribe(self())
  Notifier.publish(:updated)
  assert_receive {:notification, :updated}
end
```

## Start processes with `start_supervised!/1`

`start_supervised!/1` starts a process under the test supervisor and stops it at the end of the test, so tests do not leak processes into each other. Give the process a test-specific name, or none, so async tests do not collide on a global name.

## Replace dependencies at boundaries, through behaviours

Define a behaviour for an external dependency (an HTTP API, a mailer), use Mox to define a mock for it in tests, and pass or configure the implementation. HTTP clients often have their own test adapters, such as `Req.Test`. Avoid libraries that replace module functions globally at runtime (`:meck`, Mock): they force `async: false` and test a different module than the one that runs in production.

## Use setup for shared data

Return data from `setup` as a map and match what each test needs in its head:

```elixir
setup do
  %{user: insert_user()}
end

test "admins can delete posts", %{user: user} do
  # ...
end
```

## Other ExUnit features to reach for

- `doctest MyModule` to run the examples in `@doc`.
- `ExUnit.CaptureLog.capture_log/1` and `ExUnit.CaptureIO.capture_io/1` to check output instead of printing it.
- `@tag :tmp_dir` for a fresh temporary directory per test.
- `assert_raise ArgumentError, ~r/must be positive/, fn -> ... end` for expected exceptions.

Test public functions. Private functions are covered through the public functions that call them.
