# ExUnit tests

## Run tests concurrently unless they share global state

Start test modules with `use ExUnit.Case, async: true`. Use `async: false` only when the tests touch global state that cannot be isolated, such as the application environment, named singleton processes, or global mocks. With Ecto on PostgreSQL, the SQL sandbox lets database tests run with `async: true`. On MySQL keep database tests `async: false`; the sandbox docs say concurrent tests deadlock there.

A test double that the server calls, such as a mailer, reaches the test process without global state: register the test process in a `Registry` under the server's test-specific name, built from the test's module and name because two modules can share a test name, and let the double look it up by the name it finds in `Process.info(self(), :registered_name)`, since it runs inside the server. Start the registry once, in `test_helper.exs`, or in `setup_all` with `start_supervised!/1` when the file runs on its own. `Process.register(self(), TestMailer)` and `Application.put_env(:notify, :test_pid, self())` make the test process a singleton, which forces `async: false`.

```elixir
# Instead of (one process at a time can hold the name)
Process.register(self(), TestMailer)
# write
setup %{module: module, test: test} do
  name = Module.concat(module, test)
  {:ok, _owner} = Registry.register(TestMailer.Registry, name, nil)
  %{server: start_supervised!({Notifier, mailer: TestMailer, name: name})}
end

# deliver/2 runs inside the server, so its registered name is the test's key
def deliver(to, subject) do
  {:registered_name, server} = Process.info(self(), :registered_name)
  [{test_pid, _value}] = Registry.lookup(TestMailer.Registry, server)
  send(test_pid, {:delivered, to, subject})
  :ok
end
```

## Group tests by function and name them by behaviour

Name a `describe` block after the function under test, or after a condition its tests share, the shape the ExUnit documentation shows with a named `setup` (`describe "when the subscriber has exited" do` followed by `setup [:subscribe_and_exit]`). A block that joins two functions (`describe "subscribe/3 and subscribers/2"`) no longer says which one a failure is about. A block named after a condition, or after a requirement where the project asks for that, still states a behaviour a failing test can contradict: `describe "an update survives encoding and applying"`, not `describe "the round trip"`, which names a topic and promises nothing.

A test's name is the line a failure prints, so it says what the function did in the situation the test sets up: the value it returned, in the domain's words, or the effect it had. A name that only says the call did not fail (`"returns :ok"`, `"works"`, `"succeeds with an empty cart"`) tells the reader of a failure nothing; name the value and the condition (`"returns an error for an unknown coupon"`) or the effect (`"adds the item to the cart"`).

```elixir
# Instead of
describe "parse/1 and valid?/1" do
  test "returns :ok" do
    # ...
  end
end
# write
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

A pattern asserts the shape and binds values for further checks, without repeating fields the test does not care about. Use `==` when the whole value matters. A value the test already holds goes into the pattern with the pin operator, `^subscriber`, or the whole value is compared with `==`; a match that binds the value and an `==` on it afterwards is the shape to replace. The value under test goes on the left of `==` and the expected value on the right, whether it is the call itself or a result bound a line earlier: a failure prints left and right in that order, so `assert {:ok, "ch_1"} == result` reads as if the literal were on trial. In a test body, every match that can fail takes `assert` in front, the arrange steps included: bare, `:ok = subscribe(server, "news", self())` fails as a `MatchError` without the assertion's formatted value. A destructure that cannot fail, such as `{result, log} = with_log(...)`, needs none.

```elixir
# Instead of
{:ok, user} = Accounts.create_user(attrs)
assert user.email == "a@example.com"
assert user.role == :member
# write
assert {:ok, %User{email: "a@example.com", role: :member}} = Accounts.create_user(attrs)

# Instead of
assert [pid] = Subscriptions.subscribers(server, "news")
assert pid == self()
# write
assert Subscriptions.subscribers(server, "news") == [self()]
# or, with a value bound earlier in the test
assert [^subscriber] = Subscriptions.subscribers(server, "news")

# Instead of
assert elem(result, 0) == :error
# write
assert {:error, {:missing_field, "amount"}} = Webhook.parse(payload)

# Instead of
assert :ok == Subscriptions.subscribe(server, "news", self())
# write
assert Subscriptions.subscribe(server, "news", self()) == :ok
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

To wait for a process to exit, monitor it and assert on the `:DOWN` message instead of polling `Process.alive?/1`:

```elixir
ref = Process.monitor(pid)
assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
```

Match the reason too, `:normal`, `:shutdown` or the one the test caused: a `_` there lets a crash for another reason pass.

To assert on a GenServer's state after sending it casts, call `:sys.get_state(pid)` first, or any synchronous call to it. The process handles messages in order, so the reply means the earlier casts were handled too.

## Start processes with `start_supervised!/1`

`start_supervised!/1` starts a process under the test supervisor and stops it at the end of the test, so tests do not leak processes into each other. Give the process a test-specific name, or none, so async tests do not collide on a global name; a server that registers `__MODULE__` by default takes a test-specific name built from the context's module and test name, `Module.concat(context.module, context.test)`. To assert that a start fails, call `start_supervised/1` and match the reason. `start_link/1` called from the test links the new process to the test process, so a failed start exits the test with the same reason, and a start that unexpectedly succeeds leaves a process running under the default name.

```elixir
# Instead of
assert {:error, _reason} = Notifier.start_link(name: :notifier_without_mailer)
# write
assert {:error, {:missing_mailer, _spec}} =
         start_supervised({Notifier, name: Module.concat(context.module, context.test)})
```

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

## Capture logs with `capture_log/2`, not a handler

`ExUnit.CaptureLog.capture_log/2` returns the log output of the function it runs, and `with_log/2` returns the function's result with it. Both take the default formatter's options, so `capture_log([format: "$level $metadata$message\n", metadata: :all, colors: [enabled: false]], fn -> ... end)` gives exact control of the format and the metadata, and both run under `async: true`. A handler added with `:logger.add_handler/3` in a test does the same work and brings its own removal, `StringIO` and flushing. Crash reports from other processes are captured too; wait for their `:DOWN` message inside the function. Wrap every call that logs, the ones whose return value is under test included, so the suite prints nothing. What `capture_log` cannot do is admit a level the primary level drops: a message below `Logger.level/0` reaches no handler, so a test of a lower level raises it for the module under test with `Logger.put_module_level/2` in `setup` and `Logger.delete_module_level/1` in `on_exit`, or, when it must be global, calls `Logger.configure/1` and runs `async: false`. A crash report's content depends on the primary level alone: `Logger.Translator` prints the `State:` line and the client's stacktrace only when `Logger.level/0` is `:debug`, and a module level does not change that, so a test of what a crash report carries also needs `Logger.configure/1` and `async: false`.

```elixir
test "logs a bounced address with the message id" do
  log =
    capture_log([metadata: [:message_id]], fn ->
      assert {:error, :bounced} = Mailer.deliver(bounced_email(), message_id: "msg_1")
    end)

  assert log =~ "[warning]"
  assert log =~ "message_id=msg_1"
end
```

## Other ExUnit features to reach for

- `doctest MyModule` to run the examples in `@doc`.
- `ExUnit.CaptureIO.capture_io/1` to check printed output instead of letting it print.
- `@tag :tmp_dir` for a fresh temporary directory per test.
- `assert_raise ArgumentError, ~r/must be positive/, fn -> ... end` for expected exceptions.

Test public functions. Private functions are covered through the public functions that call them.
