"""Append one record line per graded run to the end of each case file, under "Seen so far". A
case is written only when both its gradings exist, and a line already in the file is never
added again."""
import argparse
import pathlib
import sys

from common import DEFAULT_CASES_DIR, TIERS, load_grades, run_index, run_tier

NOT_YET_RUN = "- Not yet run."


def record_lines(data, date, revision):
    label = "without skill" if data["condition"] == "baseline" else "with skill"
    keys = sorted(data["runs"], key=lambda key: (TIERS.index(run_tier(key)), run_index(key)))
    lines = []
    for key in keys:
        run = data["runs"][key]
        summary = run["summary"].strip()
        if not summary.endswith("."):
            summary += "."
        model = run.get("model_id") or run.get("model_alias") or "unavailable"
        lines.append(f"- {date}, {revision}, {model}, {label}, 1 run: {summary}")
    return lines


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--grades", type=pathlib.Path, required=True, help="the sweep's grades folder")
    parser.add_argument("--date", required=True)
    parser.add_argument("--revision", required=True, help="the short hash the runs loaded the skill from")
    parser.add_argument("--cases-dir", type=pathlib.Path, default=DEFAULT_CASES_DIR)
    args = parser.parse_args()
    grades = load_grades(args.grades)
    for case in sorted({case for case, _ in grades}):
        if (case, "baseline") not in grades or (case, "skill") not in grades:
            print(f"{case}: waiting for both gradings")
            continue
        path = args.cases_dir / f"{case}.md"
        text = path.read_text()
        present = set(text.splitlines())
        lines = record_lines(grades[(case, "baseline")], args.date, args.revision)
        lines += record_lines(grades[(case, "skill")], args.date, args.revision)
        new = [line for line in lines if line not in present]
        if not new:
            print(f"{case}: already recorded")
            continue
        body = text.rstrip().removesuffix(NOT_YET_RUN).rstrip()
        path.write_text(body + "\n" + "\n".join(new) + "\n")
        print(f"{case}: recorded {len(new)} lines")


if __name__ == "__main__":
    sys.exit(main())
