"""Tests for the sweep driver. Every test goes through a script's command line;
sessions are faked with a `claude` executable placed first on PATH."""
import gzip
import hashlib
import json
import os
import pathlib
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
import uuid
from collections import Counter

TOOLS = pathlib.Path(__file__).resolve().parent
REPO = TOOLS.parent.parent
FIRST_SWEEP = REPO / "evals" / "sweeps" / "2026-10-21"
FROZEN_README = FIRST_SWEEP / "README.md"
README = REPO / "evals" / "README.md"
CASES = REPO / "evals" / "cases"
SKILL_LINE = (
    "First read the skill at {skill}/SKILL.md and follow it, "
    "including reading any reference file it points you to for this task."
)
BASELINE_LINE = "Do not invoke any skills."
SKILL_PHRASE = "Readability rules carry the same weight as correctness rules"
MACROS_PHRASE = "Unquote each argument once"
REFUSAL = "refusing to start: the skill is installed at"
PLACEHOLDERS = ("<output>", "<evals>", "<skill>", "<project>", "<elixir-version>")
COMMAND = [
    "claude", "-p", "--model", "claude-haiku-5-5", "--permission-mode", "acceptEdits",
    "--allowedTools", "Bash(elixir:*)", "Bash(mix:*)", "Bash(elixirc:*)", "--output-format", "json",
    "--session-id", "<new for each attempt>",
]
SWEEP_MATRIX = (("claude-opus-5-5", "opus", 1), ("claude-haiku-5-5", "haiku", 2), ("claude-sonnet-5-5", "sonnet", 2))

CANDIDATES_TITLE = "Candidates (Opus and Sonnet exercised the rule and neither violated it):"
UNCONFIRMED_TITLE = "Unconfirmed (Opus or Sonnet never produced the construct the rule governs):"
CONFIRMED_TITLE = "Confirmed (a candidate in both sweeps):"
DROPPED_TITLE = "Dropped (a candidate the previous sweep had; Opus or Sonnet violated it in this one):"
UNCONFIRMED_BEFORE_TITLE = "Unconfirmed (a candidate the previous sweep had; Opus or Sonnet did not exercise it this time):"
NEW_CANDIDATES_TITLE = "New candidates (clean on Opus and Sonnet this sweep, not a candidate before):"
# The first sweep's README was written when every tier decided the lists.
FROZEN_CANDIDATES_TITLE = "Candidates (every tier exercised the rule and none violated it):"

FAKE_CLAUDE = r'''#!/usr/bin/env python3
import json, os, sys, uuid
prompt = sys.stdin.read()
args = sys.argv[1:]
model = args[args.index("--model") + 1]
mode = os.environ.get("FAKE_CLAUDE", "")
sid = args[args.index("--session-id") + 1] if "--session-id" in args else str(uuid.uuid4())
if mode == "inherit-id":
    sid = os.environ["FAKE_CLAUDE_INHERITED_ID"]
base = os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR", "~/.claude"))
folder = os.path.join(base, "projects", os.getcwd().replace("/", "-"))
os.makedirs(folder, exist_ok=True)
error_text = "There's an issue with the selected model"
synthetic = {"type": "assistant", "isApiErrorMessage": True, "message": {
    "role": "assistant", "model": "<synthetic>", "content": [{"type": "text", "text": error_text}]}}
user = {"type": "user", "message": {"role": "user", "content": prompt}}
skills = os.path.join(base, "skills")
extras = sorted(os.listdir(skills)) if os.path.isdir(skills) else []
extras += ["plugins/synced"] if os.path.isdir(os.path.join(base, "plugins", "synced")) else []
listing = {"type": "attachment", "attachment": {"type": "skill_listing", "skillCount": len(extras), "isInitial": True}}
with open("seen.json", "w") as f:
    json.dump({"extras": extras, "sync": [k for k in ("CLAUDE_CODE_SYNC_PLUGINS", "CLAUDE_CODE_SYNC_SKILLS") if k in os.environ]}, f)
if mode == "resync":
    os.makedirs(os.path.join(skills, "synced"))


def write_transcript(entries):
    with open(os.path.join(folder, sid + ".jsonl"), "w") as f:
        for entry in entries:
            f.write(json.dumps(entry) + "\n")


if mode == "refuse-identifier" and model.startswith("claude-"):
    write_transcript([user, synthetic])
    print(json.dumps({"session_id": sid, "is_error": True, "total_cost_usd": 0, "num_turns": 1, "result": error_text}))
    sys.exit(1)
reported = os.environ.get("FAKE_CLAUDE_REPORTS", "claude-haiku-5-5")
text = []
if "--add-dir" in args and not os.environ.get("FAKE_CLAUDE_NO_PHRASE"):
    text.append("@SKILL_PHRASE@")
if os.environ.get("FAKE_CLAUDE_READS") == "macros.md":
    text.append("@MACROS_PHRASE@")
answer = {"type": "assistant", "message": {"role": "assistant", "model": reported, "content": [{"type": "text", "text": " ".join(text)}]}}
if not os.environ.get("FAKE_CLAUDE_NO_TRANSCRIPT"):
    write_transcript([user, listing] + ([synthetic] if mode == "overloaded-once" else []) + [answer])
with open("webhook.ex", "w") as f:
    f.write("defmodule Webhook do\nend\n")
print(json.dumps({"session_id": sid, "total_cost_usd": 0.01, "num_turns": 1, "result": "done"}))
'''.replace("@SKILL_PHRASE@", SKILL_PHRASE).replace("@MACROS_PHRASE@", MACROS_PHRASE)


def tool(name, *args, env=None):
    return subprocess.run(
        [sys.executable, str(TOOLS / name), *map(str, args)],
        capture_output=True, text=True, cwd=REPO, env=env,
    )


def split_cells(line):
    return [cell.strip() for cell in re.split(r"(?<!\\)\|", line)[1:-1]]


def index_rows_of(text):
    lines = text.splitlines()
    start = lines.index("| Rule | Cases | Without skill |") + 2
    rows = []
    for line in lines[start:]:
        if not line.startswith("|"):
            break
        rows.append(line)
    return rows


def cases_named(cases_cell):
    if cases_cell.startswith("not provocable"):
        return []
    return [case.strip() for case in cases_cell.split(";")[0].split(",")]


def printed_rows(stdout):
    return [line for line in stdout.splitlines() if line.startswith("| ")]


def prompt_of(stdout):
    lines = stdout.splitlines()
    return lines[lines.index("prompt:") + 1:]


def command_of(stdout):
    line = next(line for line in stdout.splitlines() if line.startswith("command: "))
    return shlex.split(line[len("command: "):])


def jobs_of(stdout):
    jobs, cwd = [], None
    for line in stdout.splitlines():
        if line.startswith("cwd: "):
            cwd = line[len("cwd: "):]
        elif line.startswith("command: "):
            cmd = shlex.split(line[len("command: "):])
            jobs.append((cwd, cmd[cmd.index("--model") + 1]))
    return jobs


def bullets_after(text, title):
    lines = text.splitlines()
    rest = lines[lines.index(title) + 1:]
    while rest and not rest[0].strip():
        rest = rest[1:]
    bullets = []
    for line in rest:
        if not line.startswith("- "):
            break
        bullets.append(line)
    return bullets


def git(*args):
    return subprocess.run(["git", "-C", str(REPO), *args], capture_output=True, text=True, check=True).stdout


def copy_grades(tmp):
    grades = pathlib.Path(tmp) / "grades"
    shutil.copytree(FIRST_SWEEP / "grades", grades)
    return grades


def edit_runs(grades, case, condition, edit):
    path = grades / f"{case}-{condition}.json"
    data = json.loads(path.read_text())
    edit(data["runs"])
    path.write_text(json.dumps(data))


def set_verdict(grades, case, condition, rule, verdict, runs=None):
    def edit(all_runs):
        for key in runs or all_runs:
            all_runs[key]["verdicts"][rule] = {"verdict": verdict, "evidence": "set by the test"}
    edit_runs(grades, case, condition, edit)


def drop_rule(grades, case, condition, rule):
    def edit(all_runs):
        for run in all_runs.values():
            del run["verdicts"][rule]
    edit_runs(grades, case, condition, edit)


def set_violating(grades, case, condition, rule, count):
    def edit(all_runs):
        for i, key in enumerate(sorted(all_runs)):
            all_runs[key]["verdicts"][rule]["verdict"] = "violated" if i < count else "clean"
    edit_runs(grades, case, condition, edit)


class DetectionTest(unittest.TestCase):
    def test_skill_md_keeps_the_sentence_that_marks_a_read_of_it(self):
        skill = (REPO / "idiomatic-elixir" / "SKILL.md").read_text()
        self.assertEqual(skill.count(SKILL_PHRASE), 1)


class ReadmeIndexTest(unittest.TestCase):
    def test_live_index_parses_and_names_only_existing_cases(self):
        rows = index_rows_of(README.read_text())
        self.assertTrue(rows)
        for row in rows:
            cells = split_cells(row)
            self.assertEqual(len(cells), 3, row)
            self.assertTrue(cells[0], row)
            for case in cases_named(cells[1]):
                self.assertTrue((CASES / f"{case}.md").is_file(), f"{case!r} named in: {row}")


class AggregateTest(unittest.TestCase):
    def test_reproduces_the_first_sweep_column(self):
        r = tool("aggregate.py", FIRST_SWEEP / "grades", "--readme", FROZEN_README)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stderr, "")
        expected = index_rows_of(FROZEN_README.read_text())
        self.assertTrue(expected)
        self.assertEqual(printed_rows(r.stdout), expected)
        self.assertEqual(sum(row.endswith("| not provocable |") for row in expected), 1)

    def test_skips_a_case_listed_for_a_rule_after_the_sweep_and_says_so(self):
        rule = "Treat lists as linked lists"
        frozen = FROZEN_README.read_text()
        readme = frozen.replace(f"| {rule} | order-report |", f"| {rule} | order-report, ecto-phoenix |")
        self.assertNotEqual(readme, frozen)
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "README.md"
            path.write_text(readme)
            r = tool("aggregate.py", FIRST_SWEEP / "grades", "--readme", path)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(f"note: ecto-phoenix was not graded for the rule {rule!r}", r.stderr)
        expected = [row for row in index_rows_of(frozen) if row.startswith(f"| {rule} |")]
        self.assertEqual([row for row in printed_rows(r.stdout) if row.startswith(f"| {rule} |")],
                         [row.replace("| order-report |", "| order-report, ecto-phoenix |") for row in expected])

    def test_decides_the_first_sweep_cull_lists_by_opus_and_sonnet(self):
        r = tool("aggregate.py", FIRST_SWEEP / "grades", "--readme", FROZEN_README)
        self.assertEqual(r.returncode, 0, r.stderr)
        frozen = FROZEN_README.read_text()
        candidates = bullets_after(r.stdout, CANDIDATES_TITLE)
        unconfirmed = bullets_after(r.stdout, UNCONFIRMED_TITLE)
        for line in bullets_after(frozen, FROZEN_CANDIDATES_TITLE):
            self.assertIn(re.sub(r": Opus (\d+ runs?), Haiku \d+, Sonnet (\d+) in (.*)$", r": Opus \1, Sonnet \2 in \3; Haiku clean", line), candidates)
        for row in index_rows_of(frozen):
            rule, _, column = split_cells(row)
            rule = rule.replace("\\|", "|")
            values = dict(part.split(" ", 1) for part in column.split(", ")) if column.startswith("Opus ") else {}
            deciding = [values.get("Opus"), values.get("Sonnet")]
            self.assertEqual(any(line.startswith(f"- {rule}:") for line in candidates), deciding == ["clean", "clean"], rule)
            self.assertEqual(any(line.startswith(f"- {rule}:") for line in unconfirmed),
                             any(value in ("not exercised", "unavailable") for value in deciding), rule)

    def test_a_haiku_violation_keeps_a_candidate_and_is_printed_with_it(self):
        rule = "Treat lists as linked lists"
        with tempfile.TemporaryDirectory() as tmp:
            grades = copy_grades(tmp)
            set_verdict(grades, "order-report", "baseline", rule, "violated", runs=["baseline-haiku-1"])
            r = tool("aggregate.py", grades, "--readme", FROZEN_README, "--previous", FIRST_SWEEP / "grades")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(f"| {rule} | order-report | Opus clean, Haiku violated, Sonnet clean |", printed_rows(r.stdout))
        self.assertIn(f"- {rule}: Opus 1 run, Sonnet 2 in order-report; Haiku violated", bullets_after(r.stdout, CONFIRMED_TITLE))
        self.assertEqual(bullets_after(r.stdout, DROPPED_TITLE), ["- none"])

    def test_refuses_a_missing_verdict_naming_file_and_rule(self):
        with tempfile.TemporaryDirectory() as tmp:
            grades = copy_grades(tmp)
            path = grades / "webhook-parser-baseline.json"
            data = json.loads(path.read_text())
            del data["runs"]["baseline-haiku-1"]["verdicts"]["Naming"]
            path.write_text(json.dumps(data))
            r = tool("aggregate.py", grades, "--readme", FROZEN_README)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("webhook-parser-baseline.json", r.stderr)
        self.assertIn("Naming", r.stderr)
        self.assertIn("baseline-haiku-1", r.stderr)
        self.assertEqual(printed_rows(r.stdout), [])

    def test_refuses_a_missing_with_skill_grading_naming_file_and_rule(self):
        with tempfile.TemporaryDirectory() as tmp:
            grades = copy_grades(tmp)
            (grades / "macro-dsl-skill.json").unlink()
            r = tool("aggregate.py", grades, "--readme", FROZEN_README)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("refused: macro-dsl-skill.json is missing; the rule 'Unquote each argument once' lists macro-dsl",
                      r.stderr.splitlines())
        self.assertEqual(printed_rows(r.stdout), [])

    def test_a_tier_shows_unavailable_only_when_every_run_of_it_is(self):
        rule = "Treat lists as linked lists"
        with tempfile.TemporaryDirectory() as tmp:
            grades = copy_grades(tmp)
            set_verdict(grades, "order-report", "baseline", rule, "unavailable", runs=["baseline-sonnet-1"])
            one = tool("aggregate.py", grades, "--readme", FROZEN_README)
            set_verdict(grades, "order-report", "baseline", rule, "unavailable", runs=["baseline-sonnet-2"])
            both = tool("aggregate.py", grades, "--readme", FROZEN_README)
        self.assertEqual(one.returncode, 0, one.stderr)
        self.assertIn(f"| {rule} | order-report | Opus clean, Haiku clean, Sonnet clean |", printed_rows(one.stdout))
        self.assertIn(f"- {rule}: Opus 1 run, Sonnet 2 in order-report; Haiku clean", bullets_after(one.stdout, CANDIDATES_TITLE))
        self.assertEqual(both.returncode, 0, both.stderr)
        self.assertIn(f"| {rule} | order-report | Opus clean, Haiku clean, Sonnet unavailable |", printed_rows(both.stdout))
        self.assertIn(f"- {rule}: Opus clean, Haiku clean, Sonnet unavailable in order-report",
                      bullets_after(both.stdout, UNCONFIRMED_TITLE))
        self.assertFalse([line for line in bullets_after(both.stdout, CANDIDATES_TITLE) if line.startswith(f"- {rule}:")])

    def test_compares_with_skill_counts_and_sorts_the_previous_candidates_against_a_previous_sweep(self):
        with tempfile.TemporaryDirectory() as tmp:
            grades = copy_grades(tmp)
            set_violating(grades, "library-client", "skill", "Make polymorphism explicit", 1)
            set_violating(grades, "library-client", "skill", "Group related parameters", 2)
            set_violating(grades, "order-report", "skill", "Use the `Enum` or `Map` function made for the job", 1)
            set_violating(grades, "code-review", "skill", "Keep functions short and at one level of detail", 2)
            set_verdict(grades, "order-report", "baseline", "Treat lists as linked lists", "violated", runs=["baseline-sonnet-1"])
            set_verdict(grades, "macro-dsl", "baseline", "Write module names literally", "not exercised",
                        runs=["baseline-sonnet-1", "baseline-sonnet-2"])
            set_verdict(grades, "ecto-phoenix", "baseline", "Keep migrations to schema changes", "clean")
            r = tool("aggregate.py", grades, "--readme", FROZEN_README, "--previous", FIRST_SWEEP / "grades")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stderr, "")
        lines = r.stdout.splitlines()
        self.assertIn("- Make polymorphism explicit: without skill 3 of 5; with skill 1 of 5; was 3 of 5: improved", lines)
        self.assertIn("- Group related parameters: without skill 4 of 5; with skill 2 of 5; was 0 of 5: regressed", lines)
        self.assertIn("- Use the `Enum` or `Map` function made for the job: without skill 0 of 5; with skill 1 of 5; "
                      "was 2 of 5: unchanged", lines)
        self.assertIn("- Keep functions short and at one level of detail: without skill 5 of 5; with skill 2 of 5; "
                      "was 1 of 5: unchanged", lines)
        confirmed = bullets_after(r.stdout, CONFIRMED_TITLE)
        self.assertIn("- Unquote each argument once: Opus 1 run, Sonnet 2 in macro-dsl; Haiku clean", confirmed)
        self.assertFalse([line for line in confirmed if line.startswith("- Treat lists as linked lists:")])
        self.assertEqual(bullets_after(r.stdout, DROPPED_TITLE),
                         ["- Treat lists as linked lists: Opus clean, Haiku clean, Sonnet violated in order-report"])
        self.assertEqual(bullets_after(r.stdout, UNCONFIRMED_BEFORE_TITLE),
                         ["- Write module names literally: Opus clean, Haiku clean, Sonnet not exercised in macro-dsl"])
        self.assertEqual(bullets_after(r.stdout, NEW_CANDIDATES_TITLE),
                         ["- Keep migrations to schema changes: Opus 1 run, Sonnet 2 in ecto-phoenix; Haiku clean"])

    def test_compares_over_the_shared_cases_when_the_case_sets_differ(self):
        rule = "Treat lists as linked lists"
        readme = FROZEN_README.read_text().replace(f"| {rule} | order-report |", f"| {rule} | order-report, ecto-phoenix |")
        previous_note = f"note (previous sweep): ecto-phoenix was not graded for the rule {rule!r} in this sweep; its runs are left out of that row"
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "README.md"
            path.write_text(readme)
            grades = copy_grades(tmp)
            set_verdict(grades, "ecto-phoenix", "baseline", rule, "clean")
            set_verdict(grades, "ecto-phoenix", "skill", rule, "violated")
            shared = tool("aggregate.py", grades, "--readme", path, "--previous", FIRST_SWEEP / "grades")
            drop_rule(grades, "order-report", "baseline", rule)
            drop_rule(grades, "order-report", "skill", rule)
            disjoint = tool("aggregate.py", grades, "--readme", path, "--previous", FIRST_SWEEP / "grades")
        self.assertEqual(shared.returncode, 0, shared.stderr)
        self.assertIn(f"- {rule}: without skill 0 of 10; with skill 5 of 10; over order-report only: 0 of 5, was 0 of 5: unchanged",
                      shared.stdout.splitlines())
        self.assertEqual(shared.stderr.splitlines(), [previous_note])
        self.assertEqual(disjoint.returncode, 0, disjoint.stderr)
        self.assertIn(f"- {rule}: without skill 0 of 5; with skill 5 of 5; not comparable: the previous sweep graded none of ecto-phoenix",
                      disjoint.stdout.splitlines())
        self.assertEqual(disjoint.stderr.splitlines(), [
            f"note: order-report was not graded for the rule {rule!r} in this sweep; its runs are left out of that row",
            previous_note,
        ])


class DryRunTest(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp()).resolve()
        self.addCleanup(shutil.rmtree, self.tmp)
        self.root = self.tmp / "root"
        self.absent = self.tmp / "no-skill-here"

    def run_dry(self, condition, case="webhook-parser", skills_folder=None, run_root=None):
        return tool(
            "run.py", case, condition, "--n", "1", "--models", "claude-haiku-5-5",
            "--output", self.tmp / "out", "--run-root", run_root or self.root,
            "--skills-folder", skills_folder or self.absent, "--dry-run",
        )

    def test_with_skill_haiku_command(self):
        r = self.run_dry("skill")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(command_of(r.stdout), COMMAND + ["--add-dir", f"{self.root}/skill"])
        cwd = next(line for line in r.stdout.splitlines() if line.startswith("cwd: "))[5:]
        self.assertEqual(cwd, str(self.root / "runs" / "webhook-parser" / "skill-haiku-1"))
        self.assertFalse(cwd.startswith(str(REPO)))
        self.assertEqual(prompt_of(r.stdout)[0], SKILL_LINE.format(skill=self.root / "skill"))

    def test_baseline_command(self):
        r = self.run_dry("baseline")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(command_of(r.stdout), COMMAND)
        self.assertEqual(prompt_of(r.stdout)[-1], BASELINE_LINE)

    def test_either_condition_is_refused_while_the_skill_is_installed(self):
        installed = self.tmp / "skills" / "idiomatic-elixir"
        installed.mkdir(parents=True)
        linked = self.tmp / "linked" / "idiomatic-elixir"
        linked.parent.mkdir()
        linked.symlink_to(self.tmp / "nowhere")
        for condition, folder in (("baseline", installed), ("skill", installed), ("baseline", linked)):
            with self.subTest(condition=condition, folder=folder.name):
                r = self.run_dry(condition, skills_folder=folder)
                self.assertNotEqual(r.returncode, 0)
                self.assertTrue(r.stderr.startswith(f"{REFUSAL} {folder}"), r.stderr)
                self.assertIn("move the folder or symlink out of the skills folder", r.stderr)
                self.assertNotIn("command:", r.stdout)

    def test_a_renamed_symlink_to_the_skill_in_the_skills_folder_is_refused(self):
        skills = self.tmp / "renamed-skills"
        skills.mkdir()
        renamed = skills / "idiomatic-elixir.aside"
        renamed.symlink_to(REPO / "idiomatic-elixir")
        r = self.run_dry("skill", skills_folder=skills / "idiomatic-elixir")
        self.assertNotEqual(r.returncode, 0)
        self.assertTrue(r.stderr.startswith(f"{REFUSAL} {renamed}"), r.stderr)

    def test_either_condition_proceeds_when_the_skill_is_not_installed(self):
        for condition in ("baseline", "skill"):
            with self.subTest(condition=condition):
                r = self.run_dry(condition, skills_folder=self.absent)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn("command:", r.stdout)

    def test_refuses_a_run_root_inside_the_repository(self):
        inside = REPO / "evals" / "tmp-run-root-for-the-test"
        r = self.run_dry("skill", run_root=inside)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("inside the repository", r.stderr)
        self.assertNotIn("command:", r.stdout)
        self.assertFalse(inside.exists())

    def test_every_case_prompt_names_the_session_folder_and_leaves_no_placeholder(self):
        for path in sorted(CASES.glob("*.md")):
            with self.subTest(case=path.stem):
                r = self.run_dry("skill", case=path.stem)
                self.assertEqual(r.returncode, 0, r.stderr)
                prompt = "\n".join(prompt_of(r.stdout))
                self.assertIn(str(self.root / "runs" / path.stem / "skill-haiku-1"), prompt)
                for placeholder in PLACEHOLDERS:
                    self.assertNotIn(placeholder, prompt)


class SweepDryRunTest(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp()).resolve()
        self.addCleanup(shutil.rmtree, self.tmp)
        self.root = self.tmp / "root"
        self.absent = self.tmp / "no-skill-here"

    def run_dry(self, *args, skills_folder=None):
        return tool(
            "sweep.py", "--dry-run", "--output", self.tmp / "out", "--run-root", self.root,
            "--skills-folder", skills_folder or self.absent, *args,
        )

    def session(self, case, condition, tier, n):
        return str(self.root / "runs" / case / f"{condition}-{tier}-{n}")

    def test_refuses_every_job_list_while_the_skill_is_installed(self):
        installed = self.tmp / "skills" / "idiomatic-elixir"
        installed.mkdir(parents=True)
        for args in ((), ("--conditions", "skill", "--cases", "macro-dsl")):
            with self.subTest(args=args):
                r = self.run_dry(*args, skills_folder=installed)
                self.assertNotEqual(r.returncode, 0)
                self.assertTrue(r.stderr.startswith(f"{REFUSAL} {installed}"), r.stderr)
                self.assertNotIn("cwd:", r.stdout)

    def test_default_matrix_runs_baseline_before_skill_with_one_opus_and_two_haiku_and_sonnet_per_case(self):
        r = self.run_dry()
        self.assertEqual(r.returncode, 0, r.stderr)
        jobs = jobs_of(r.stdout)
        cases = sorted(path.stem for path in CASES.glob("*.md"))
        self.assertEqual(jobs, [
            (self.session(case, condition, tier, n), model)
            for case in cases
            for condition in ("baseline", "skill")
            for model, tier, count in SWEEP_MATRIX
            for n in range(1, count + 1)
        ])
        counts = Counter((pathlib.Path(cwd).name.split("-")[0], model) for cwd, model in jobs)
        self.assertEqual(counts, {
            (condition, model): count * len(cases)
            for condition in ("baseline", "skill")
            for model, _, count in SWEEP_MATRIX
        })

    def test_cases_conditions_and_matrix_select_the_jobs(self):
        r = self.run_dry("--cases", "webhook-parser,macro-dsl", "--conditions", "skill",
                         "--models", "claude-sonnet-5-5=1,claude-haiku-5-5=2")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(jobs_of(r.stdout), [
            (self.session("webhook-parser", "skill", "sonnet", 1), "claude-sonnet-5-5"),
            (self.session("webhook-parser", "skill", "haiku", 1), "claude-haiku-5-5"),
            (self.session("webhook-parser", "skill", "haiku", 2), "claude-haiku-5-5"),
            (self.session("macro-dsl", "skill", "sonnet", 1), "claude-sonnet-5-5"),
            (self.session("macro-dsl", "skill", "haiku", 1), "claude-haiku-5-5"),
            (self.session("macro-dsl", "skill", "haiku", 2), "claude-haiku-5-5"),
        ])


class RecordsTest(unittest.TestCase):
    ARGS = ("--date", "2026-10-22", "--revision", "abc1234")

    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp)
        (self.tmp / "grades").mkdir()
        (self.tmp / "cases").mkdir()
        for cond in ("baseline", "skill"):
            shutil.copy(FIRST_SWEEP / "grades" / f"macro-dsl-{cond}.json", self.tmp / "grades")
        shutil.copy(CASES / "macro-dsl.md", self.tmp / "cases")
        self.case = self.tmp / "cases" / "macro-dsl.md"

    def records(self):
        return tool("records.py", "--grades", self.tmp / "grades", "--cases-dir", self.tmp / "cases", *self.ARGS)

    def test_adds_the_ten_lines_once(self):
        before = self.case.read_text().count("\n")
        first = self.records()
        after_first = self.case.read_text()
        second = self.records()
        after_second = self.case.read_text()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(after_first.count("\n") - before, 10)
        self.assertEqual(after_first.count("- 2026-10-22, abc1234, "), 10)
        self.assertEqual(after_second, after_first)

    def test_names_the_alias_then_unavailable_when_a_run_has_no_model_id(self):
        path = self.tmp / "grades" / "macro-dsl-skill.json"
        data = json.loads(path.read_text())
        aliased, bare = data["runs"]["skill-haiku-1"], data["runs"]["skill-sonnet-1"]
        del aliased["model_id"]
        aliased["model_alias"] = "haiku"
        del bare["model_id"]
        bare.pop("model_alias", None)
        path.write_text(json.dumps(data))
        r = self.records()
        self.assertEqual(r.returncode, 0, r.stderr)
        lines = self.case.read_text().splitlines()
        self.assertIn(f"- 2026-10-22, abc1234, haiku, with skill, 1 run: {self.sentence(aliased)}", lines)
        self.assertIn(f"- 2026-10-22, abc1234, unavailable, with skill, 1 run: {self.sentence(bare)}", lines)

    @staticmethod
    def sentence(run):
        summary = run["summary"].strip()
        return summary if summary.endswith(".") else summary + "."


class ResultProvenanceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp()).resolve()
        self.addCleanup(shutil.rmtree, self.tmp)
        fake = self.tmp / "bin" / "claude"
        fake.parent.mkdir()
        fake.write_text(FAKE_CLAUDE)
        fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
        self.root = self.tmp / "root"
        self.out = self.tmp / "out"
        self.home = self.tmp / "home"
        # A CLAUDE_CONFIG_DIR in the caller's shell would point run.py at the real transcripts.
        inherited = {key: value for key, value in os.environ.items() if key != "CLAUDE_CONFIG_DIR"}
        self.env = dict(inherited, HOME=str(self.home), PATH=f"{fake.parent}{os.pathsep}{os.environ['PATH']}")

    def run_with_skill(self, **env):
        return tool(
            "run.py", "webhook-parser", "skill", "--n", "1", "--models", "claude-haiku-5-5",
            "--output", self.out, "--run-root", self.root, "--skills-folder", self.tmp / "absent",
            env=dict(self.env, **env),
        )

    @property
    def session(self):
        return self.root / "runs" / "webhook-parser" / "skill-haiku-1"

    @property
    def kept(self):
        return self.out / "webhook-parser" / "skill-haiku-1"

    def result(self, folder=None):
        return json.loads(((folder or self.kept) / "result.json").read_text())

    def test_with_skill_result_carries_skill_hash_revision_and_flag(self):
        r = self.run_with_skill()
        self.assertEqual(r.returncode, 0, r.stderr)
        rec = self.result()
        skill = self.root / "skill"
        digest = hashlib.sha256()
        for path in sorted(p for p in skill.rglob("*") if p.is_file()):
            digest.update(str(path.relative_to(skill)).encode())
            digest.update(b"\0")
            digest.update(path.read_bytes())
            digest.update(b"\0")
        self.assertEqual(rec["skill_hash"], digest.hexdigest())
        self.assertEqual(rec["head"], git("rev-parse", "HEAD").strip())
        self.assertEqual(rec["uncommitted"], bool(git("status", "--porcelain", "--", "idiomatic-elixir", "evals/cases", "evals/tools", "evals/README.md").strip()))
        self.assertEqual(rec["model"], "claude-haiku-5-5")
        self.assertEqual(rec["model_arg"], "claude-haiku-5-5")
        self.assertEqual(rec["model_id"], ["claude-haiku-5-5"])
        self.assertEqual(rec["reads"], ["SKILL.md"])
        self.assertEqual(rec["rc"], 0)
        self.assertEqual(rec["files"], ["webhook.ex"])
        self.assertEqual(rec["format_ok"], {"webhook.ex": True})
        self.assertTrue(rec["compiles"]["webhook.ex"][0])
        self.assertTrue((self.kept / "prompt.txt").exists())
        with gzip.open(self.kept / "transcript.jsonl.gz", "rt") as f:
            self.assertIn("claude-haiku-5-5", f.read())
        self.assertFalse((self.kept / "transcript.jsonl").exists())

    def test_writes_the_result_in_place_without_leaving_a_staged_copy(self):
        r = self.run_with_skill()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.result(self.session), self.result(self.kept))
        self.assertEqual(list(self.root.rglob("*.tmp")), [])
        self.assertEqual(list(self.out.rglob("*.tmp")), [])

    def test_falls_back_to_the_alias_when_the_identifier_is_refused(self):
        r = self.run_with_skill(FAKE_CLAUDE="refuse-identifier")
        self.assertEqual(r.returncode, 0, r.stderr)
        rec = self.result()
        self.assertEqual(rec["model_arg"], "haiku")
        self.assertIn('"is_error": true', rec["refusal"])
        self.assertEqual(rec["model_id"], ["claude-haiku-5-5"])
        self.assertEqual(rec["reads"], ["SKILL.md"])
        self.assertEqual(rec["rc"], 0)

    def test_ignores_a_synthetic_error_entry_before_the_answer(self):
        r = self.run_with_skill(FAKE_CLAUDE="overloaded-once")
        self.assertEqual(r.returncode, 0, r.stderr)
        rec = self.result()
        self.assertEqual(rec["model_arg"], "claude-haiku-5-5")
        self.assertNotIn("refusal", rec)
        self.assertEqual(rec["model_id"], ["claude-haiku-5-5"])
        self.assertEqual(rec["rc"], 0)
        with gzip.open(self.kept / "transcript.jsonl.gz", "rt") as f:
            self.assertIn("<synthetic>", f.read())

    def test_fails_the_run_when_the_transcript_reports_another_model(self):
        r = self.run_with_skill(FAKE_CLAUDE_REPORTS="claude-haiku-4-5")
        self.assertEqual(r.returncode, 0, r.stderr)
        rec = self.result()
        self.assertEqual(rec["rc"], "model mismatch")
        self.assertEqual(rec["model_id"], ["claude-haiku-4-5"])

    def test_model_mismatch_outranks_skill_not_read(self):
        r = self.run_with_skill(FAKE_CLAUDE_REPORTS="claude-haiku-4-5", FAKE_CLAUDE_NO_PHRASE="1")
        self.assertEqual(r.returncode, 0, r.stderr)
        rec = self.result()
        self.assertEqual(rec["rc"], "model mismatch")
        self.assertEqual(rec["reads"], [])

    def test_records_the_reference_file_the_transcript_shows_it_read(self):
        r = self.run_with_skill(FAKE_CLAUDE_READS="macros.md")
        self.assertEqual(r.returncode, 0, r.stderr)
        rec = self.result()
        self.assertEqual(rec["reads"], ["SKILL.md", "macros.md"])
        self.assertEqual(rec["rc"], 0)

    def test_fails_a_with_skill_run_whose_transcript_lacks_the_skill_phrase(self):
        r = self.run_with_skill(FAKE_CLAUDE_NO_PHRASE="1")
        self.assertEqual(r.returncode, 0, r.stderr)
        rec = self.result()
        self.assertEqual(rec["reads"], [])
        self.assertEqual(rec["model_id"], ["claude-haiku-5-5"])
        self.assertEqual(rec["rc"], "skill not read")
        self.assertIn("webhook-parser/skill-haiku-1 skill not read", r.stdout)

    def test_fails_a_run_that_left_no_transcript(self):
        r = self.run_with_skill(FAKE_CLAUDE_NO_TRANSCRIPT="1")
        self.assertEqual(r.returncode, 0, r.stderr)
        rec = self.result()
        self.assertNotIn("model_id", rec)
        self.assertNotIn("transcript", rec)
        self.assertEqual(rec["rc"], "no transcript")
        self.assertFalse((self.kept / "transcript.jsonl.gz").exists())

    def test_clears_a_run_folder_left_by_an_interrupted_session_and_skips_a_kept_run(self):
        self.session.mkdir(parents=True)
        (self.session / "stray.ex").write_text("defmodule Stray do\nend\n")
        (self.session / "result.json").write_text("{}")
        first = self.run_with_skill()
        self.assertEqual(first.returncode, 0, first.stderr)
        rec = self.result()
        self.assertEqual(rec["rc"], 0)
        self.assertEqual(rec["files"], ["webhook.ex"])
        self.assertFalse((self.session / "stray.ex").exists())
        self.assertFalse((self.kept / "stray.ex").exists())
        second = self.run_with_skill()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("webhook-parser/skill-haiku-1 exists", second.stdout)
        self.assertEqual(self.result(), rec)

    def test_finds_the_transcript_under_claude_config_dir_when_it_is_set(self):
        config = self.tmp / "config"
        r = self.run_with_skill(CLAUDE_CONFIG_DIR=str(config))
        self.assertEqual(r.returncode, 0, r.stderr)
        rec = self.result()
        self.assertEqual(rec["model_id"], ["claude-haiku-5-5"])
        self.assertEqual(rec["rc"], 0)
        self.assertTrue(rec["transcript"].startswith(str(config)), rec["transcript"])
        self.assertFalse((self.home / ".claude").exists())

    def test_gives_each_attempt_its_own_session_id_and_finds_the_transcript_by_it(self):
        r = self.run_with_skill()
        self.assertEqual(r.returncode, 0, r.stderr)
        rec = self.result()
        self.assertEqual(str(uuid.UUID(rec["session_id"])), rec["session_id"])
        self.assertTrue(rec["transcript"].endswith(f"/{rec['session_id']}.jsonl"), rec["transcript"])

    def test_never_reads_another_session_transcript_that_shares_the_reported_id(self):
        inherited = str(uuid.uuid4())
        stale = self.home / ".claude" / "projects" / "-elsewhere" / f"{inherited}.jsonl"
        stale.parent.mkdir(parents=True)
        stale.write_text(json.dumps({"type": "assistant", "message": {"model": "claude-haiku-5-5", "content": [{"type": "text", "text": SKILL_PHRASE}]}}) + "\n")
        r = self.run_with_skill(FAKE_CLAUDE="inherit-id", FAKE_CLAUDE_INHERITED_ID=inherited)
        self.assertEqual(r.returncode, 0, r.stderr)
        rec = self.result()
        self.assertEqual(rec["rc"], "no transcript")
        self.assertNotIn("transcript", rec)

    def give_home_extras(self):
        claude = self.home / ".claude"
        for folder in ("skills/session-start-hook", "skills/synced/docx", "plugins/synced/council"):
            (claude / folder).mkdir(parents=True)
        return claude

    def test_hides_the_skills_and_synced_plugins_from_the_session_and_puts_them_back(self):
        claude = self.give_home_extras()
        r = self.run_with_skill(CLAUDE_CODE_SYNC_PLUGINS="true", CLAUDE_CODE_SYNC_SKILLS="true")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("hidden for the run: plugins/synced, skills/session-start-hook, skills/synced", r.stdout)
        self.assertEqual(json.loads((self.kept / "seen.json").read_text()), {"extras": [], "sync": []})
        self.assertEqual(self.result()["skills_listed"], 0)
        for folder in ("skills/session-start-hook", "skills/synced/docx", "plugins/synced/council"):
            self.assertTrue((claude / folder).is_dir(), folder)
        self.assertFalse((claude / "hidden-during-sweep").exists())

    def test_a_sweep_hides_the_extras_for_its_runs_and_notes_them(self):
        claude = self.give_home_extras()
        r = tool(
            "sweep.py", "--cases", "webhook-parser", "--conditions", "baseline", "--models", "claude-haiku-5-5=1",
            "--output", self.out, "--run-root", self.root, "--skills-folder", self.tmp / "absent", env=self.env,
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        log = (self.root / "progress.log").read_text()
        self.assertIn("hidden for the sweep: plugins/synced, skills/session-start-hook, skills/synced", log)
        seen = json.loads((self.out / "webhook-parser" / "baseline-haiku-1" / "seen.json").read_text())
        self.assertEqual(seen["extras"], [])
        self.assertTrue((claude / "skills" / "synced" / "docx").is_dir())

    def test_refuses_to_start_while_an_earlier_sweep_left_folders_hidden(self):
        left = self.home / ".claude" / "hidden-during-sweep" / "skills" / "synced"
        left.mkdir(parents=True)
        r = self.run_with_skill()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("did not put back", r.stderr)
        self.assertFalse(self.kept.exists())
        self.assertTrue(left.is_dir())

    def test_keeps_the_hidden_copy_when_a_folder_came_back_during_the_run(self):
        claude = self.give_home_extras()
        r = self.run_with_skill(FAKE_CLAUDE="resync")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(f"{claude / 'skills' / 'synced'} came back during the sweep", r.stderr)
        self.assertTrue((claude / "hidden-during-sweep" / "skills" / "synced" / "docx").is_dir())
        self.assertTrue((claude / "skills" / "session-start-hook").is_dir())
        self.assertTrue((claude / "plugins" / "synced" / "council").is_dir())

    def test_postprocess_refreshes_the_result_in_the_run_root_and_the_kept_copy(self):
        r = self.run_with_skill()
        self.assertEqual(r.returncode, 0, r.stderr)
        for folder in (self.session, self.kept):
            stale = self.result(folder)
            stale["files"] = []
            (folder / "result.json").write_text(json.dumps(stale))
        with open(self.session / "transcript.jsonl", "a") as f:
            f.write(json.dumps({"type": "assistant", "message": {"role": "assistant", "model": "claude-haiku-5-5",
                                                                   "content": [{"type": "text", "text": MACROS_PHRASE}]}}) + "\n")
        p = tool("postprocess.py", self.root / "runs", "--output", self.out, env=self.env)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("webhook-parser/skill-haiku-1 ['claude-haiku-5-5'] reads=SKILL.md,macros.md files=webhook.ex", p.stdout)
        for folder in (self.session, self.kept):
            rec = self.result(folder)
            self.assertEqual(rec["files"], ["webhook.ex"])
            self.assertEqual(rec["reads"], ["SKILL.md", "macros.md"])
            self.assertEqual(rec["rc"], 0)
        self.assertEqual(list(self.root.rglob("*.tmp")), [])


if __name__ == "__main__":
    unittest.main()
