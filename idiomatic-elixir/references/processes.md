# Processes and OTP

## Decide whether you need a process

A process models something at runtime: state that changes and is shared between callers, work that runs concurrently, or a part of the system whose failures should be isolated. Modules and functions organize code. If a module's functions would work as plain functions, do not put them in a GenServer. Every call to a single process waits in its mailbox, so a process used for code organization becomes a bottleneck.

Libraries should not impose processes or concurrency on their users. Give users plain functions and let them decide.

## Pick the abstraction that matches the job

| Job | Use |
| --- | --- |
| Run one piece of work concurrently and maybe await its result | `Task` (under `Task.Supervisor`) |
| Map over a collection concurrently | `Task.async_stream/3` with `:max_concurrency` and `:timeout` |
| Fire-and-forget work | `Task.Supervisor.start_child/2` |
| Simple shared state read and replaced with functions | `Agent` |
| State plus a message protocol, timers, monitors, or side effects | `GenServer` |
| Data read by many processes, or counters updated from many processes | ETS table owned by a process |
| Processes started at runtime, one per user, room, or job | `DynamicSupervisor` plus `Registry` for names |

When a `Task` starts exchanging messages with other processes, or an `Agent` starts running work beyond reading and updating its state, rewrite it as a `GenServer`.

## Keep each process behind one module

All interaction with a process goes through the functions of the module that defines it. Other modules never call `GenServer.call/3`, `GenServer.cast/2`, `send/2`, or `Agent.update/2` on it directly. The owning module controls the shape of the state and the messages.

```elixir
# Instead of, scattered across modules
Agent.update(bucket, fn state -> Map.put(state, "milk", 3) end)
Agent.get(bucket, fn state -> state end)
# write
defmodule MyApp.Bucket do
  use Agent

  def start_link(opts) do
    Agent.start_link(fn -> %{} end, opts)
  end

  def get(bucket, key), do: Agent.get(bucket, &Map.get(&1, key))
  def put(bucket, key, value), do: Agent.update(bucket, &Map.put(&1, key, value))
end
```

Put the client functions and the server callbacks of a GenServer in the same module, client functions first. Mark callbacks with `@impl true` (or `@impl GenServer`).

## Write GenServers that stay responsive

- Keep `init/1` fast, because the supervisor waits for it. Move slow setup into `handle_continue/2` by returning `{:ok, state, {:continue, :load}}`.
- Do not do slow work (HTTP calls, large queries) inside `handle_call/3`; it blocks every other caller. Do the work in the caller's process, or start a task and reply later with `GenServer.reply/2`.
- Use `call` by default. `cast` gives no back-pressure and no error to the sender, so a fast producer can flood the mailbox.
- Schedule periodic work with `Process.send_after(self(), :tick, interval)` and reschedule it in `handle_info/2`.
- Any state that grows per key (per user, per connection) needs a way to remove entries, such as a periodic sweep or an expiry check, or the process will grow without limit.
- Register singleton processes with `name: __MODULE__`, but let `start_link/1` accept a `:name` option so tests can start their own instance. Register dynamic processes through `Registry` with `{:via, Registry, {MyApp.Registry, key}}`. Never build atoms for process names from runtime data.

## Use ETS for data many processes read

A GenServer serializes access. When many processes read shared data, or update counters, put the data in an ETS table owned by a supervised process, and read and write it from the calling processes.

```elixir
defmodule MyApp.Counters do
  use GenServer

  @table __MODULE__

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def increment(key), do: :ets.update_counter(@table, key, 1, {key, 0})

  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, count}] -> count
      [] -> 0
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, nil}
  end
end
```

Callers may write to a shared table directly only with operations that are atomic on their own: `:ets.update_counter/4`, `:ets.insert_new/2`, `:ets.delete/2`, or an `:ets.insert/2` whose new value does not depend on what was there. A `lookup` followed by an `insert` computed from the looked-up value is a race: two processes can read the same old value and both write, and the second write discards the first. For example, a rate limiter that reads a user's timestamps, checks the count, and writes the list back lets concurrent requests exceed the limit. Either change the data so an atomic operation does the job (a counter per user per time window with `:ets.update_counter/4`, or insert one row per request first, then count with `:ets.select_count/2` and delete your row if the count is over the limit), or send that operation through the owner process.

## Supervise every long-lived process

Start processes as children of a supervisor, so they start in a known order, stop in reverse order on shutdown, restart according to a strategy, and show up in tools such as Observer and LiveDashboard. A bare `spawn/1` or `Task.start/1` outside a supervisor has none of this.

```elixir
children = [
  MyApp.Repo,
  {Task.Supervisor, name: MyApp.TaskSupervisor},
  {MyApp.Cache, sweep_interval: :timer.minutes(1)},
  MyAppWeb.Endpoint
]

Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
```

To run several instances of the same module, give each one a distinct ID with `Supervisor.child_spec({MyApp.Counter, name: :other}, id: :other)`.

Use `Task.Supervisor.async_nolink/2` when the caller must survive the task crashing. Use `Task.async/1` only when the same process awaits the result.

## Send processes only the data they need

Messages are copied into the receiving process. So are all variables captured by an anonymous function passed to `spawn/1`, `Task.async/1`, or `Task.async_stream/3`. Reading one field inside the closure still copies the whole variable.

```elixir
# Instead of (copies the whole conn, including the request body)
Task.Supervisor.start_child(MyApp.TaskSupervisor, fn -> log_ip(conn.remote_ip) end)
GenServer.cast(pid, {:report_ip, conn})
# write
ip = conn.remote_ip
Task.Supervisor.start_child(MyApp.TaskSupervisor, fn -> log_ip(ip) end)
GenServer.cast(pid, {:report_ip, conn.remote_ip})
```

If only the receiving process needs some data, let it fetch the data itself. For data that rarely changes and is read everywhere, consider `:persistent_term`.
