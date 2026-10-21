"""Fill in the mechanical facts about a finished run: the model its transcript reports, which
skill files it read, the files it wrote, and the format, compile and project checks."""
import argparse
import gzip
import json
import os
import pathlib
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

from common import INPUT_SUFFIX, PARALLEL, detection_phrases

NEEDS_PHOENIX_AND_ECTO = {"ecto-phoenix"}


def transcript_text(rundir):
    plain, packed = rundir / "transcript.jsonl", rundir / "transcript.jsonl.gz"
    if plain.exists():
        return plain.read_text()
    if packed.exists():
        with gzip.open(packed, "rt") as f:
            return f.read()
    return None


def model_ids(text):
    ids = set()
    for line in text.splitlines():
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        # An API error comes back as an assistant turn with a placeholder model, so it is not
        # evidence that any model answered.
        if entry.get("type") == "assistant" and not entry.get("isApiErrorMessage"):
            model = (entry.get("message") or {}).get("model")
            if model and model != "<synthetic>":
                ids.add(model)
    return sorted(ids)


def reads(text, phrases):
    return sorted(file for file, phrase in phrases.items() if phrase in text)


def sh(cmd, cwd):
    try:
        r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=300)
    except subprocess.TimeoutExpired:
        return False, f"{' '.join(cmd)} timed out after 300 seconds"
    return r.returncode == 0, (r.stdout + r.stderr)[-600:]


def enrich(rundir, rec, phrases):
    text = transcript_text(rundir)
    if text is not None:
        rec["model_id"] = model_ids(text)
        rec["reads"] = reads(text, phrases)
    written = sorted(
        p.name for p in rundir.iterdir()
        if p.is_file() and p.suffix in (".ex", ".exs", ".md") and not p.name.endswith(INPUT_SUFFIX)
    )
    rec["files"] = written
    sources = [f for f in written if f.endswith((".ex", ".exs"))]
    if sources:
        rec["format_ok"] = {f: sh(["mix", "format", "--check-formatted", f], rundir)[0] for f in sources}
    compilable = [f for f in sources if f.endswith(".ex") and rec["case"] not in NEEDS_PHOENIX_AND_ECTO]
    if compilable:
        rec["compiles"] = {f: sh(["elixir", f], rundir) for f in compilable}
    project = rundir / rec["case"]
    if (project / "mix.exs").exists():
        rec["project"] = {
            "format_ok": sh(["mix", "format", "--check-formatted"], project)[0],
            "compile": sh(["mix", "compile", "--force", "--warnings-as-errors"], project),
            "test": sh(["mix", "test"], project),
            "credo": sh(["mix", "credo", "--strict"], project),
        }
    return rec


def write_result(path, rec):
    staged = path.with_name(path.name + ".tmp")
    staged.write_text(json.dumps(rec, indent=1))
    os.replace(staged, path)


def refresh(result, output, phrases):
    rundir = result.parent
    rec = enrich(rundir, json.loads(result.read_text()), phrases)
    write_result(result, rec)
    if output:
        kept = output / rec["case"] / rundir.name
        if kept.is_dir():
            shutil.copy(result, kept / "result.json")
    return rec


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folder", type=pathlib.Path, help="holds <case>/<condition>-<tier>-<n>/result.json")
    parser.add_argument("--output", type=pathlib.Path, help="also refresh each run's result.json in this sweep folder")
    args = parser.parse_args()
    phrases = detection_phrases()
    results = sorted(args.folder.glob("*/*/result.json"))
    with ThreadPoolExecutor(max_workers=PARALLEL) as pool:
        for rec in pool.map(lambda result: refresh(result, args.output, phrases), results):
            print(rec["id"], rec.get("model_id"), "reads=" + (",".join(rec.get("reads", [])) or "-"), "files=" + ",".join(rec["files"]))


if __name__ == "__main__":
    sys.exit(main())
