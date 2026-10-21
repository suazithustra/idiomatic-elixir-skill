"""Run one case in one condition for a list of models, the way the first sweep did: one fresh
non-interactive session per run, in its own folder outside the repository, kept afterwards
under the output folder without build artefacts."""
import argparse
import dataclasses
import glob
import gzip
import json
import os
import pathlib
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor

import postprocess
from common import (
    CONDITIONS, DEFAULT_CASES_DIR, DEFAULT_SKILL_DIR, DEFAULT_SKILLS_FOLDER, INPUT_SUFFIX, PINNED_MODELS,
    REPO, detection_phrases, folder_hash, git_head, git_uncommitted, run_name, tier_of,
)

BASELINE_LINE = "Do not invoke any skills."
SKILL_LINE = (
    "First read the skill at {skill}/SKILL.md and follow it, "
    "including reading any reference file it points you to for this task."
)
MOVE_ASIDE = (
    "refusing to start: the skill is installed at {path}; move the folder or symlink aside "
    'for the sweep and restore it after (evals/README.md, "Running a case", step 2)'
)
SESSION_TIMEOUT = 1500

_prepare_lock = threading.Lock()
_sessions = set()
_sessions_lock = threading.Lock()
_stopping = threading.Event()


@dataclasses.dataclass
class Setup:
    cases_dir: pathlib.Path
    skill_dir: pathlib.Path
    output: pathlib.Path
    run_root: pathlib.Path
    skills_folder: pathlib.Path
    elixir_version: str
    head: str
    uncommitted: bool
    phrases: dict

    @property
    def skill_copy(self):
        return self.run_root / "skill"


def add_common_arguments(parser):
    parser.add_argument("--cases-dir", type=pathlib.Path, default=DEFAULT_CASES_DIR, help="folder of case files")
    parser.add_argument("--skill", type=pathlib.Path, default=DEFAULT_SKILL_DIR, help="the skill folder to copy and load")
    parser.add_argument("--output", type=pathlib.Path, required=True, help="where finished runs are kept, such as evals/sweeps/<date>")
    parser.add_argument("--run-root", type=pathlib.Path, help="scratch folder outside the repository for the sessions; a fresh temporary folder by default")
    parser.add_argument("--skills-folder", type=pathlib.Path, default=DEFAULT_SKILLS_FOLDER, help="where the session would find the installed skill; a baseline run refuses to start while it exists")
    parser.add_argument("--dry-run", action="store_true", help="print each session's folder, command and prompt without starting it")


def elixir_version():
    out = subprocess.run(["elixir", "--version"], capture_output=True, text=True).stdout
    m = re.search(r"Elixir (\d+\.\d+\.\d+)", out)
    if not m:
        sys.exit("cannot read the Elixir version from `elixir --version`")
    return m.group(1)


def setup_from(args):
    run_root = (args.run_root or pathlib.Path(tempfile.mkdtemp(prefix="idiomatic-elixir-sweep-"))).expanduser().resolve()
    if run_root.is_relative_to(REPO):
        sys.exit(f"the run root {run_root} is inside the repository; sessions must not see the skill or the case checks")
    run_root.mkdir(parents=True, exist_ok=True)
    return Setup(
        cases_dir=args.cases_dir.resolve(),
        skill_dir=args.skill.resolve(),
        output=args.output.resolve(),
        run_root=run_root,
        skills_folder=args.skills_folder.expanduser(),
        elixir_version=elixir_version(),
        head=git_head(),
        uncommitted=git_uncommitted(),
        phrases=detection_phrases(),
    )


def refuse_if_installed(skills_folder):
    if os.path.lexists(skills_folder):
        sys.exit(MOVE_ASIDE.format(path=skills_folder))


def prompt_for(cases_dir, case):
    text = (cases_dir / f"{case}.md").read_text()
    return re.search(r"```text\n(.*?)```", text, re.S).group(1).strip()


def session_dir(setup, case, condition, tier, n):
    return setup.run_root / "runs" / case / run_name(condition, tier, n)


def build_prompt(setup, case, condition, sdir):
    prompt = (
        prompt_for(setup.cases_dir, case)
        .replace("<output>", str(sdir))
        .replace("<evals>", str(sdir))
        .replace("<skill>", str(setup.skill_copy))
        .replace("<elixir-version>", setup.elixir_version)
        .replace("<project>", str(sdir / case))
    )
    if condition == "skill":
        return f"{SKILL_LINE.format(skill=setup.skill_copy)}\n\n{prompt}"
    return f"{prompt}\n\n{BASELINE_LINE}"


def command(model_arg, condition, skill_copy):
    cmd = [
        "claude", "-p", "--model", model_arg, "--permission-mode", "acceptEdits",
        "--allowedTools", "Bash(elixir:*)", "Bash(mix:*)", "Bash(elixirc:*)", "--output-format", "json",
    ]
    if condition == "skill":
        cmd += ["--add-dir", str(skill_copy)]
    return cmd


def prepare_skill(setup):
    with _prepare_lock:
        if not setup.skill_copy.exists():
            shutil.copytree(setup.skill_dir, setup.skill_copy)
        skill_hash = folder_hash(setup.skill_copy)
        if skill_hash != folder_hash(setup.skill_dir):
            raise RuntimeError(f"the skill copy under {setup.run_root} differs from {setup.skill_dir}; use a fresh run root")
        return skill_hash


def precompile_dependencies(project):
    for step in (["mix", "deps.get"], ["mix", "compile"]):
        subprocess.run(step, cwd=project, check=True, capture_output=True, text=True)


def prepare_inputs(setup, case):
    with _prepare_lock:
        inputs = setup.run_root / "inputs"
        inputs.mkdir(parents=True, exist_ok=True)
        single = setup.cases_dir / f"{case}{INPUT_SUFFIX}"
        if single.exists() and not (inputs / single.name).exists():
            shutil.copy(single, inputs / single.name)
        project = setup.cases_dir / case
        if project.is_dir() and not (inputs / case).exists():
            shutil.copytree(project, inputs / case)
            if (inputs / case / "mix.exs").exists():
                try:
                    precompile_dependencies(inputs / case)
                except BaseException:
                    shutil.rmtree(inputs / case)
                    raise


def stage_inputs(setup, case, sdir):
    inputs = setup.run_root / "inputs"
    single = inputs / f"{case}{INPUT_SUFFIX}"
    if single.exists():
        shutil.copy(single, sdir / single.name)
    if (inputs / case).is_dir():
        shutil.copytree(inputs / case, sdir / case, dirs_exist_ok=True)


def launch(cmd, cwd, prompt):
    start = time.time()
    # A session of its own makes the process group ours to kill, so ending a session also ends
    # the commands it started.
    proc = subprocess.Popen(
        cmd, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, start_new_session=True,
    )
    with _sessions_lock:
        _sessions.add(proc)
    try:
        try:
            stdout, stderr = proc.communicate(prompt, timeout=SESSION_TIMEOUT)
            rc = "interrupted" if _stopping.is_set() else proc.returncode
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            stdout, stderr = proc.communicate()
            rc = "timeout"
    finally:
        with _sessions_lock:
            _sessions.discard(proc)
    try:
        parsed = json.loads(stdout)
    except ValueError:
        parsed = None
    if not isinstance(parsed, dict):
        parsed = None
    return {"rc": rc, "seconds": round(time.time() - start), "stdout": stdout, "stderr": stderr, "parsed": parsed}


def stop_sessions():
    _stopping.set()
    with _sessions_lock:
        for proc in list(_sessions):
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass


def refused(outcome, model_ids):
    """The model never answered: the run ended in error and no assistant turn carried a model.
    The command line checks the model on the first request, not at startup, so a refusal can
    come back as an error result with a session id."""
    failed = (isinstance(outcome["rc"], int) and outcome["rc"] > 0) or bool((outcome["parsed"] or {}).get("is_error"))
    return failed and not model_ids


def find_transcript(session_id):
    base = os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR", "~/.claude"))
    hits = glob.glob(f"{base}/projects/*/{session_id}.jsonl") if session_id else []
    return pathlib.Path(hits[0]) if hits else None


def attempt(setup, sdir, model_arg, condition, prompt):
    # Variadic options such as --add-dir swallow a trailing prompt, so the prompt goes through stdin.
    outcome = launch(command(model_arg, condition, setup.skill_copy), sdir, prompt)
    transcript = find_transcript((outcome["parsed"] or {}).get("session_id"))
    model_ids = postprocess.model_ids(transcript.read_text()) if transcript else []
    return outcome, transcript, model_ids


def keep(sdir, dest):
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(sdir, dest, ignore=shutil.ignore_patterns("_build", "deps"))
    plain = dest / "transcript.jsonl"
    if plain.exists():
        with open(plain, "rb") as src, gzip.open(dest / "transcript.jsonl.gz", "wb") as dst:
            shutil.copyfileobj(src, dst)
        plain.unlink()


def describe(setup, case, condition, model, n):
    sdir = session_dir(setup, case, condition, tier_of(model), n)
    print(f"cwd: {sdir}")
    print("command: " + shlex.join(command(model, condition, setup.skill_copy)))
    print("prompt:")
    print(build_prompt(setup, case, condition, sdir))


def run_one(setup, case, condition, model, n):
    tier = tier_of(model)
    sdir = session_dir(setup, case, condition, tier, n)
    rid = f"{case}/{sdir.name}"
    kept = setup.output / case / sdir.name
    if (kept / "result.json").exists():
        return rid, "exists"
    if sdir.exists():
        shutil.rmtree(sdir)
    prompt = build_prompt(setup, case, condition, sdir)
    skill_hash = prepare_skill(setup) if condition == "skill" else None
    prepare_inputs(setup, case)
    sdir.mkdir(parents=True, exist_ok=True)
    stage_inputs(setup, case, sdir)
    (sdir / "prompt.txt").write_text(prompt)
    rec = {"id": rid, "case": case, "condition": condition, "model_alias": tier, "model": model, "model_arg": model, "n": n}
    outcome, transcript, model_ids = attempt(setup, sdir, model, condition, prompt)
    if refused(outcome, model_ids):
        rec["refusal"] = (outcome["stderr"] or outcome["stdout"])[-300:]
        rec["model_arg"] = tier
        outcome, transcript, model_ids = attempt(setup, sdir, tier, condition, prompt)
    if outcome["rc"] == "interrupted":
        return rid, "interrupted"
    rec["rc"] = "unavailable" if refused(outcome, model_ids) else outcome["rc"]
    rec["seconds"] = outcome["seconds"]
    parsed = outcome["parsed"]
    if parsed:
        rec.update({
            "session_id": parsed.get("session_id"), "cost_usd": parsed.get("total_cost_usd"),
            "num_turns": parsed.get("num_turns"), "result": (parsed.get("result") or "")[:500],
        })
    else:
        rec["raw"] = (outcome["stdout"] + outcome["stderr"])[-800:]
    if transcript:
        rec["transcript"] = str(transcript)
        shutil.copy(transcript, sdir / "transcript.jsonl")
    rec["head"] = setup.head
    rec["uncommitted"] = setup.uncommitted
    if condition == "skill":
        rec["skill_hash"] = skill_hash
    postprocess.enrich(sdir, rec, setup.phrases)
    if any(reported != model for reported in rec.get("model_id", [])):
        rec["rc"] = "model mismatch"
    elif rec["rc"] == 0 and not rec.get("model_id"):
        rec["rc"] = "no transcript"
    elif rec["rc"] == 0 and condition == "skill" and "SKILL.md" not in rec.get("reads", []):
        rec["rc"] = "skill not read"
    postprocess.write_result(sdir / "result.json", rec)
    keep(sdir, kept)
    return rid, rec["rc"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("case")
    parser.add_argument("condition", choices=CONDITIONS)
    parser.add_argument("--models", default=",".join(PINNED_MODELS), help="comma-separated model identifiers")
    parser.add_argument("--n", type=int, default=1, help="the run index, which names the run folder")
    add_common_arguments(parser)
    args = parser.parse_args()
    setup = setup_from(args)
    refuse_if_installed(setup.skills_folder)
    models = args.models.split(",")
    if args.dry_run:
        for model in models:
            describe(setup, args.case, args.condition, model, args.n)
        return
    print("run root", setup.run_root)
    with ThreadPoolExecutor(max_workers=len(models)) as pool:
        for rid, rc in pool.map(lambda model: run_one(setup, args.case, args.condition, model, args.n), models):
            print(rid, rc)


if __name__ == "__main__":
    sys.exit(main())
