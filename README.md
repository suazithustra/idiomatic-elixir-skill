# Idiomatic Elixir

A lightweight agent skill for Elixir developers that attempts to fill in known gaps in code quality.

This skill gives the agent a set of rules for discovered cases and is tested against an evaluation suite to cull redundancy as models improve. Rules for specialized areas are referenced in separate files to economize token consumption. The skill follows the [Agent Skills specification](https://agentskills.io/specification), so it works with any agent that supports skills.

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
| `testing.md` | ExUnit |
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

Most agents that support skills read `~/.agents/skills/` and `.agents/skills/`. Claude Code reads only its own directories. Some agents also have their own directories (for example `~/.gemini/skills/` or `~/.copilot/skills/`); see your agent's documentation.

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
evals/                 test prompts for checking changes to the skill
LICENSE                Apache License 2.0
```

## Contributing

Contributions are welcome, especially rules drawn from real Elixir output that was not idiomatic. Readability rules are as welcome as correctness rules.

### Adding or changing a rule

1. Check that the rule isn't already there under another name. Search `SKILL.md` and `references/` for the functions and patterns it involves.
2. Put rules that apply to all Elixir code in `SKILL.md`. Put rules that apply to one topic in the matching reference file.
3. Write the rule in the same shape as the existing ones: a heading that says what to write, one or two sentences on why, and a wrong-then-right example where it helps.

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

4. Run every code example, and check every claim about Elixir behavior, on a current Elixir version before you submit.
5. Keep `SKILL.md` under about 500 lines, as the specification recommends. If it grows past that, move topic-specific rules into reference files.
6. Keep the frontmatter to the fields defined in the specification. Some tools reject a skill with extra fields.

### Testing a change

`evals/` contains test prompts covering webhook parsing, a rate limiter, a report over CSV data, a library client, a code review with planted problems, and a change to a small Mix project with Credo and tests. Each case lists what to check in the output. `evals/README.md` explains how to run them with and without the skill.

Run the cases related to your change before and after it, and describe what you saw in the pull request.

## License

Licensed under the [Apache License 2.0](LICENSE).

Some rules and examples are adapted from the Elixir anti-patterns guides by the Elixir Team (Apache License 2.0) and the Elixir Code Smells catalog by Lucas Vegi (MIT License). See [`idiomatic-elixir/NOTICE`](idiomatic-elixir/NOTICE).
