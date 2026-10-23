import hashlib
import json
import os
import pathlib
import re
import subprocess
from typing import NamedTuple

TOOLS = pathlib.Path(__file__).resolve().parent
REPO = TOOLS.parent.parent
README = REPO / "evals" / "README.md"
DEFAULT_CASES_DIR = REPO / "evals" / "cases"
DEFAULT_SKILL_DIR = REPO / "idiomatic-elixir"
DEFAULT_SKILLS_FOLDER = pathlib.Path("~/.claude/skills/idiomatic-elixir")
INPUT_SUFFIX = "-input.ex"
CONDITIONS = ("baseline", "skill")
PARALLEL = 5
# A cloud session passes these to the sessions it starts, which then fetch the account's plugins
# and skills again into the folders the sweep has just hidden.
SYNC_VARIABLES = ("CLAUDE_CODE_SYNC_PLUGINS", "CLAUDE_CODE_SYNC_SKILLS")

# The identifiers the first sweep's transcripts reported, each with its runs per case in a full
# sweep. An alias such as "haiku" can move to another model later, so runs pass the identifier
# and fall back to the alias only when the command line refuses it.
SWEEP_RUNS = {"claude-opus-5-5": 1, "claude-haiku-5-5": 2, "claude-sonnet-5-5": 2}
PINNED_MODELS = list(SWEEP_RUNS)

INDEX_HEADER = "| Rule | Cases | Without skill |"
PHRASES_HEADER = "| File | Phrase |"
SKILL_PHRASE = "Readability rules carry the same weight as correctness rules"


def claude_home():
    return pathlib.Path(os.environ.get("CLAUDE_CONFIG_DIR", "~/.claude")).expanduser()


def tier_of(model):
    parts = model.split("-")
    return parts[1] if parts[0] == "claude" and len(parts) > 1 else model


TIERS = [tier_of(model) for model in PINNED_MODELS]
# The cull lists are decided by the tiers people hand the skill's kind of work to. Haiku breaks
# rules the other two keep, so counting it would drop rules the skill's readers already see
# followed; its value is printed with each candidate instead.
DECIDING_TIERS = ("opus", "sonnet")


def run_name(condition, tier, n):
    return f"{condition}-{tier}-{n}"


def run_tier(run_key):
    return run_key.split("-")[1]


def run_index(run_key):
    return int(run_key.split("-")[2])


def split_cells(line):
    return [cell.strip() for cell in re.split(r"(?<!\\)\|", line)[1:-1]]


def table_after(lines, header):
    start = lines.index(header) + 2
    rows = []
    for line in lines[start:]:
        if not line.startswith("|"):
            break
        rows.append(line)
    return rows


def readme_lines(text=None):
    return (text if text is not None else README.read_text()).splitlines()


class IndexRow(NamedTuple):
    rule: str
    cases: str
    line: str

    def with_value(self, value):
        return self.line[: self.line.rfind("|", 0, len(self.line) - 1) + 1] + f" {value} |"


def index_rows(readme_text=None):
    rows = []
    for line in table_after(readme_lines(readme_text), INDEX_HEADER):
        rule, cases, _ = split_cells(line)
        rows.append(IndexRow(rule.replace("\\|", "|"), cases, line))
    return rows


def cases_named(cases_cell):
    if cases_cell.startswith("not provocable"):
        return []
    return [case.strip() for case in cases_cell.split(";")[0].split(",")]


def detection_phrases(readme_text=None):
    phrases = {"SKILL.md": SKILL_PHRASE}
    for line in table_after(readme_lines(readme_text), PHRASES_HEADER):
        file, phrase = split_cells(line)
        phrases[file.strip("`")] = phrase.strip("`")
    return phrases


def load_grades(folder):
    grades = {}
    for path in sorted(pathlib.Path(folder).glob("*.json")):
        data = json.loads(path.read_text())
        data["file"] = path.name
        grades[(data["case"], data["condition"])] = data
    return grades


def git(*args):
    return subprocess.run(["git", "-C", str(REPO), *args], capture_output=True, text=True, check=True).stdout


def git_head():
    return git("rev-parse", "HEAD").strip()


PROCEDURE_PATHS = ("idiomatic-elixir", "evals/cases", "evals/tools", "evals/README.md")


def git_uncommitted():
    return bool(git("status", "--porcelain", "--", *PROCEDURE_PATHS).strip())


def folder_hash(folder):
    folder = pathlib.Path(folder)
    digest = hashlib.sha256()
    for path in sorted(p for p in folder.rglob("*") if p.is_file()):
        digest.update(str(path.relative_to(folder)).encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()
