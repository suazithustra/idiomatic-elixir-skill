# Idiomatic Elixir

A lightweight agent skill for Elixir developers that attempts to fill in known gaps in code quality.

This skill gives the agent a set of rules for discovered cases and is tested against an evaluation suite to cull redundancies as models improve. Rules for specialized areas are referenced in separate files to economize token consumption. The skill follows the [Agent Skills specification](https://agentskills.io/specification), so it works with any agent that supports skills.

## What it covers

`SKILL.md` holds the rules that apply to all Elixir code:

- pattern matching and map access
- control flow, `with`, and error tuples
- collections, dates, and money
- modeling data at the boundaries of a system
- configuration
- naming conventions
- readability: comments and documentation, function size, pipelines
- final steps when a shell is available: format, compile, Credo, tests

Topic-specific rules live in `references/`, which the agent reads only when a task involves that topic:

| File | Topic |
| --- | --- |
| `processes.md` | GenServer, Agent, Task, ETS (Erlang Term Storage), supervision |
| `library-design.md` | Hex packages and public APIs: options, configuration, error types |
| `macros.md` | macros, `use`, and compile-time code |
| `ex_unit.md` | ExUnit |
| `ecto-phoenix.md` | Ecto schemas, queries, migrations, Phoenix controllers and contexts |

The rules target current Elixir and were checked against Elixir 1.20. A few rules name the Elixir or Ecto version that introduced a function they rely on.

## Installation

The skill is the `idiomatic-elixir/` folder. The rest of this repository is for development. Install it with one of the tools below, or copy the folder by hand.

### With the `skills` CLI

[`skills`](https://github.com/vercel-labs/skills) detects the agents you have installed and puts the skill in the right directory for each. It needs Node.js.

```bash
npx skills add suazithustra/idiomatic-elixir-skill
```

This installs into the current project. Add `-g` to install for all your projects, or `-a <agent>` to pick one agent, for example `-a claude-code`.

### With the GitHub CLI

`gh skill` needs GitHub CLI 2.90 or later and is in preview.

```bash
gh skill install suazithustra/idiomatic-elixir-skill idiomatic-elixir --agent claude-code --scope user
```

`--agent` takes values such as `claude-code`, `codex`, `cursor`, `gemini-cli`, and `github-copilot`, which is the default. `--scope user` installs for all your projects, and `--scope project`, the default, installs into the current repository.

### With Codex's skill installer

Codex includes a `$skill-installer` skill. Ask Codex:

```text
$skill-installer install https://github.com/suazithustra/idiomatic-elixir-skill/tree/main/idiomatic-elixir
```

It installs into `~/.codex/skills/` (or `$CODEX_HOME/skills/`) for all your projects, and Codex picks the skill up on your next message.

### By hand

Clone the repository and copy the `idiomatic-elixir/` folder into your agent's skills directory:

```bash
git clone https://github.com/suazithustra/idiomatic-elixir-skill.git
cp -R idiomatic-elixir-skill/idiomatic-elixir ~/.claude/skills/
```

| Agent | All your projects | One project, shared with its team |
| --- | --- | --- |
| Claude Code | `~/.claude/skills/` | `.claude/skills/` |
| Codex, Gemini CLI, GitHub Copilot, Cursor, OpenCode, Amp, Windsurf | `~/.agents/skills/` | `.agents/skills/` |

Most agents that support skills read `~/.agents/skills/` and `.agents/skills/`. Claude Code reads only its own directories. Codex also reads `~/.codex/skills/` (or `$CODEX_HOME/skills/`), which is where its installer puts skills. Some agents also have their own directories (for example `~/.gemini/skills/` or `~/.copilot/skills/`); see your agent's documentation.

In the Claude apps and the Claude API, skills are uploaded rather than copied into a directory; see Anthropic's documentation for the steps.

## Usage

An agent loads the skill when a task involves Elixir code, whether you ask it to write, change, or review that code. You can also ask for it by name, for example: "Review `lib/my_app/importer.ex` using the idiomatic-elixir skill."

When reviewing, the skill asks the agent to name the rule behind each finding and apply them when making improvements.

## Repository layout

```text
idiomatic-elixir/      the skill
  SKILL.md             rules for all Elixir code
  references/          topic-specific rules
  LICENSE.txt          Apache License 2.0
  NOTICE               copyright and credits for adapted material
evals/                 checks on the skill and its test prompts
  cases/               one prompt per case, with its inputs
  sweeps/              dated run records: outputs, transcripts, gradings
LICENSE                Apache License 2.0
```

## Using the skill alongside Phoenix's generated AGENTS.md

`mix phx.new` (Phoenix 1.8.16) writes an `AGENTS.md` into every new project. Most of it is Phoenix-specific guidance this skill does not cover: layouts, HEEx (HTML-aware Embedded Elixir) templates, streams, hooks and forms. Some of it repeats rules here (atoms from input, `is_` prefixes, `start_supervised!/1`, waiting for messages instead of sleeping, preloading associations, map access on structs) without the reasons. A few of its statements are wrong or overstated. These were checked on 2026-10-21 against Elixir 1.20.3, Phoenix LiveView 1.2.13, Ecto 3.13.5 and phoenix_ecto 4.7.0, and this skill follows the checked behaviour:

- Its sample marked `VALID` for rebinding the result of an `if` has no `else`, so `socket` becomes `nil` whenever the socket is not connected:

  ```elixir
  socket =
    if connected?(socket) do
      assign(socket, :val, val)
    end
  ```

  The rule "Assign the result of `if`, `case`, and `Enum` calls" here shows the `else`.
- "**Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors": nesting compiles, and Phoenix's own router nests a module. One module per file stays the convention under "Naming".
- "`DynamicSupervisor` and `Registry`, require names in the child spec": `Registry` does; `DynamicSupervisor` does not.
- On `Task.async_stream/3`, "The majority of times you will want to pass `timeout: :infinity`": the five-second default is the only bound on an item that hangs, so `references/processes.md` keeps a timeout.
- "You **must** use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields": `get_change/3`, `fetch_change/2` and `fetch_field/2` are the API too, and `phx.gen.auth` uses `get_change`.
- "prepend to stream - `stream(socket, :messages, [new_msg], at: -1)`": `at: -1` appends; `at: 0` prepends.
- "LiveView streams are *not* enumerable": `Phoenix.LiveView.LiveStream` implements `Enumerable`. The real limit is that the server keeps no copy of the items, so filtering means refetching, which the file's own recipe does.
- "You are FORBIDDEN from accessing the changeset in the template as it will cause errors": `<.form for={@changeset}>` and `@changeset.valid?` work; only `@changeset[:field]` raises, because structs do not implement `Access`.

This skill works best without the generated file. The two overlap on the general Elixir rules, the file states its rules without reasons, and where they disagree an agent holds two instructions and follows each some of the time. If you keep `AGENTS.md`, keep its Phoenix-specific parts and remove the general Elixir ones this skill covers. If this skill gets something wrong, or conflicts with your project in a way it should not, open an issue or a pull request.

## Contributing

Contributions are welcome, especially rules drawn from real Elixir output that was not idiomatic. Readability rules are as welcome as correctness rules.

### Adding or changing a rule

1. Check that the rule isn't already there under another name. Search `SKILL.md` and `references/` for the functions and patterns it involves.
2. Put rules that apply to all Elixir code in `SKILL.md`. Put rules that apply to one topic in the matching reference file.
3. Write the rule in the same shape as the existing ones: a heading that says what to write, a wrong-then-right example where it helps, and as many sentences as it takes to name the shape to write, the shape it replaces, what goes wrong with the replaced shape, and the test an agent can apply. A sentence that does none of those is cut; brevity itself is not a goal. The sweeps under `evals/` show that a rule takes when it names the exact shape agents were writing and shows it.

   ````markdown
   ### Use `and`, `or`, `not` when the operands are booleans

   `and`, `or`, and `not` raise if their first operand is not a boolean, so they document and check intent. `&&`, `||`, and `!` accept any value.

   ```elixir
   # Instead of
   if is_binary(name) && age >= 18 do
   # write
   if is_binary(name) and age >= 18 do
   ```
   ````

4. Run `elixir evals/check_skill.exs`. It parses, formats, and compiles the code examples and checks the rule index in `evals/README.md`. It cannot see a wrong claim or an example that compiles but misbehaves, so also run every example by hand and check every claim about Elixir behavior on a current Elixir version before you submit.
5. Keep `SKILL.md` under about 500 lines, as the specification recommends. If it grows past that, move topic-specific rules into reference files.
6. Keep the frontmatter to the fields defined in the specification. Some tools reject a skill with extra fields.

### Testing a change

`evals/cases/` contains test prompts covering webhook parsing, a rate limiter, a report over CSV data, a library client, a macro-based router, ExUnit tests for a GenServer, a Phoenix context with Ecto, a code review with planted problems, and a change to a small Mix project with Credo and tests. Each case lists what to check in the output. `evals/README.md` explains how to run them with and without the skill.

Run the cases related to your change before and after it, and describe what you saw in the pull request.

## License

Licensed under the [Apache License 2.0](LICENSE).

Some rules and examples are adapted from the Elixir anti-patterns guides by the Elixir Team (Apache License 2.0) and the Elixir Code Smells catalog by Lucas Vegi (MIT License). See [`idiomatic-elixir/NOTICE`](idiomatic-elixir/NOTICE).
