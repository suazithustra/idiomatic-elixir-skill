# Sweep tools

The scripts that ran the sweep of 2026-10-21, kept so a check batch or a full sweep is one command and a later sweep repeats the first one's conditions. They are Python 3 with no third-party packages and need the `claude` command line, Elixir and Mix on the path. Nothing in the skill points here, so agents never load these files.

| Script | Does |
| --- | --- |
| `run.py` | Runs one case in one condition for a list of models, one fresh session per model. |
| `sweep.py` | Runs a matrix of cases, conditions and models through `run.py`, five sessions at a time. |
| `postprocess.py` | Re-reads finished runs and fills in the mechanical facts in each `result.json`. `run.py` already does this once per run. |
| `records.py` | Appends one record line per graded run under each case's "Seen so far", never twice. |
| `aggregate.py` | Folds a sweep's gradings into the index column, the run-level counts and the cull lists. |
| `grader-brief.md` | The brief given to the grading session for one case and condition. |
| `test_tools.py` | Tests, run with `python3 -m unittest evals/tools/test_tools.py`. Sessions are faked with a `claude` executable placed first on PATH. |

## A full sweep

Move the installed skill aside first (by default `~/.claude/skills/idiomatic-elixir`; pass `--skills-folder` if it lives elsewhere). A run in either condition refuses to start while that path exists, or while any other entry of that skills folder resolves to the skill folder (a renamed symlink is still listed to the session as a skill): a session that can load the installed skill is not a baseline, and a with-skill run must load only the copy the prompt names. Everything else in that skills folder, and the synced plugins folder `~/.claude/plugins/synced/` a cloud session fills, the scripts hide themselves: they move each entry into `~/.claude/hidden-during-sweep/` before the first session, put it back when the sweep ends or is interrupted, and start sessions without `CLAUDE_CODE_SYNC_PLUGINS` and `CLAUDE_CODE_SYNC_SKILLS`, which would fetch them again. If a hidden folder reappears during the sweep, its hidden copy stays where it is and the script says so; a later sweep refuses to start until that folder is empty. Then:

```
python3 evals/tools/sweep.py --output evals/sweeps/<date>
```

This runs every case file in `evals/cases/`, baseline before skill, with Opus once and Haiku and Sonnet twice each, the matrix `claude-opus-5-5=1,claude-haiku-5-5=2,claude-sonnet-5-5=2`. Sessions run in their own folders under a run root outside the repository, a fresh temporary folder unless `--run-root` names one; the first line of output says where. A session's folder holds only the case's input files, so the run cannot see the skill, the case checks or the repository. The skill folder (`idiomatic-elixir/` by default, or `--skill`) is copied into the run root at launch and that copy is granted to with-skill runs. Finished runs are copied into the output folder without `_build` and `deps`, with the transcript gzipped. To resume an interrupted sweep, run the same command with the same `--run-root`: a run whose kept copy under the output folder has a `result.json` is skipped, and a run root whose skill copy no longer matches the skill folder is refused, so a resumed sweep loads the text its `skill_hash` names.

## A check batch

```
python3 evals/tools/sweep.py --output evals/sweeps/<date>-check --cases shop-project --conditions skill --models claude-haiku-5-5=2,claude-sonnet-5-5=2
```

`--cases` takes a comma-separated subset and `--conditions` one or both of `baseline,skill`. Batches for several cases queue through the same five-session cap. One run of one case:

```
python3 evals/tools/run.py webhook-parser skill --models claude-haiku-5-5 --n 1 --output evals/sweeps/<date>
```

`--dry-run` on either script prints each session's folder, command and prompt without starting anything.

## What a run records

Each run lands at `<output>/<case>/<condition>-<tier>-<n>/` with its outputs, `prompt.txt`, `transcript.jsonl.gz` and `result.json`. The result carries the fields of the first sweep (`id`, `case`, `condition`, `model_alias`, `n`, `rc`, `seconds`, `session_id`, `cost_usd`, `num_turns`, `result`, `transcript`, `model_id`) plus `reads` (skill files the transcript shows it read, found by the phrases in `evals/README.md`), `skills_listed` (how many skills the session was shown), `files` (what it wrote), `format_ok`, `compiles` or `project` checks where the case allows, `head` (the repository's `HEAD`) and `uncommitted` (whether `idiomatic-elixir/`, `evals/cases/`, `evals/tools/` or `evals/README.md` had uncommitted changes; sweep output under `evals/sweeps/` does not count). A with-skill run also carries `skill_hash`, one digest over every file of the skill copy it loaded. Each attempt passes the session a fresh `--session-id` and finds its transcript by that identifier: a session started from inside another one otherwise takes over the outer session's identifier, and every run's transcript would share it.

Models are pinned by identifier: `model` is the identifier requested and `model_arg` what the command line was given. When the command line refuses an identifier, the run is retried with the tier's alias (`opus`, `haiku`, `sonnet`) and `refusal` keeps the error text; if the transcript then reports another identifier, `rc` is `model mismatch`, and if neither route works, `rc` is `unavailable`. A tier with no accepted route shows as unavailable in the index column.

`rc` is `0` only when the transcript names the pinned model and, for a with-skill run, shows a read of `SKILL.md`. Otherwise it is `no transcript`, `skill not read`, `model mismatch`, `timeout`, `unavailable` (both the identifier and the alias refused) or `interrupted` (the sweep was stopped with Ctrl-C; nothing is kept for such a run). A resumed sweep skips a run only when its kept copy under the output folder has a `result.json`; otherwise it removes the run's folder left in the run root and starts the run again. `result.json` is written in one step, as a temporary file renamed into place.

## After the runs

Grade one case and condition at a time with `grader-brief.md`, filling in its placeholders; the grader writes `<output>/grades/<case>-<condition>.json`. Every rule the index lists for the case needs a verdict in every run, or the aggregation refuses. Then:

```
python3 evals/tools/records.py --grades evals/sweeps/<date>/grades --date <date> --revision <short hash>
python3 evals/tools/aggregate.py evals/sweeps/<date>/grades --previous evals/sweeps/<previous date>/grades
```

`records.py` writes a case only when both its gradings exist and skips lines already present. `aggregate.py` prints the index table body with the "Without skill" column computed from the baseline gradings, the violating-run counts per rule in both conditions, and the cull lists; with `--previous` it also says per rule whether the with-skill count improved (fell by at least two), stayed unchanged or regressed, and sorts the previous sweep's candidates into confirmed, dropped and unconfirmed. Opus and Sonnet decide the cull lists; Haiku's value is printed with each candidate (`evals/README.md`, "Cull candidates", says why). Check batches get no record lines and no column.

If a run's facts need refreshing, for instance after the detection phrases change, `python3 evals/tools/postprocess.py <run-root>/runs --output evals/sweeps/<date>` recomputes them where the sessions ran and copies each `result.json` into the sweep folder. A Mix project's checks need its dependencies, which the sweep folder does not keep.
