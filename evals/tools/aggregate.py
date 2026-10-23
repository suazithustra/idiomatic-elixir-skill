"""Fold a sweep's gradings into the "Without skill" column of the rule index, print the run-level
counts behind it and the cull lists, and refuse when a grading lacks a verdict the index needs."""
import argparse
import pathlib
import sys
from typing import NamedTuple

from common import CONDITIONS, DECIDING_TIERS, README, TIERS, cases_named, index_rows, load_grades, run_tier

ORDER = {"violated": 0, "clean": 1, "not exercised": 2, "unavailable": 3}


class RuleRuns(NamedTuple):
    cases: list
    by_condition: dict


def fold(verdicts):
    return min(verdicts, key=ORDER.get) if verdicts else "unavailable"


def collect(grades, rows):
    table, problems, notes = {}, [], []
    for row in rows:
        cases = cases_named(row.cases)
        if not cases:
            continue
        graded = []
        by_condition = {condition: {} for condition in CONDITIONS}
        for case in cases:
            for condition in CONDITIONS:
                if (case, condition) not in grades:
                    problems.append(f"{case}-{condition}.json is missing; the rule {row.rule!r} lists {case}")
            runs = [(condition, run_key, run)
                    for condition in CONDITIONS if (case, condition) in grades
                    for run_key, run in grades[(case, condition)]["runs"].items()]
            if not runs:
                continue
            if all(run.get("verdicts", {}).get(row.rule) is None for _, _, run in runs):
                notes.append(f"{case} was not graded for the rule {row.rule!r} in this sweep; its runs are left out of that row")
                continue
            graded.append(case)
            for condition, run_key, run in runs:
                verdict = run.get("verdicts", {}).get(row.rule)
                if verdict is None:
                    problems.append(f"{grades[(case, condition)]['file']}: run {run_key} has no verdict for the rule {row.rule!r}")
                    continue
                by_condition[condition].setdefault(run_tier(run_key), []).append((case, verdict["verdict"]))
        table[row.rule] = RuleRuns(graded, by_condition)
    return table, problems, notes


def verdicts_of(per_tier, tier):
    return [verdict for _, verdict in per_tier.get(tier, [])]


def tier_values(per_tier):
    return {tier: fold(verdicts_of(per_tier, tier)) for tier in TIERS}


def column(per_tier):
    return ", ".join(f"{tier.capitalize()} {value}" for tier, value in tier_values(per_tier).items())


def violating(per_tier, cases=None):
    runs = [verdict for tier_runs in per_tier.values() for case, verdict in tier_runs if cases is None or case in cases]
    return sum(verdict == "violated" for verdict in runs), len(runs)


def deciding_values(per_tier):
    values = tier_values(per_tier)
    return [values[tier] for tier in DECIDING_TIERS]


def candidate(per_tier):
    return all(value == "clean" for value in deciding_values(per_tier))


def unconfirmed(per_tier):
    return any(value in ("not exercised", "unavailable") for value in deciding_values(per_tier))


def dropped(per_tier):
    return "violated" in deciding_values(per_tier)


def candidate_line(rule, cases, per_tier):
    counts = []
    for tier in DECIDING_TIERS:
        per_case = [sum(c == case for c, _ in per_tier.get(tier, [])) for case in cases]
        uniform = len(set(per_case)) == 1
        n = per_case[0] if uniform else sum(per_case)
        unit = (" run" if n == 1 else " runs") if tier == DECIDING_TIERS[0] else ""
        counts.append(f"{tier.capitalize()} {n}{unit}" + ("" if uniform else " in total"))
    others = ", ".join(f"{tier.capitalize()} {value}" for tier, value in tier_values(per_tier).items() if tier not in DECIDING_TIERS)
    return f"- {rule}: {', '.join(counts)} in {', '.join(sorted(cases))}; {others}"


def value_line(rule, cases, per_tier):
    return f"- {rule}: {column(per_tier)} in {', '.join(sorted(cases))}"


def change(previous, current):
    if previous - current >= 2:
        return "improved"
    if previous == 0 and current >= 2:
        return "regressed"
    return "unchanged"


def comparison(runs, earlier):
    shared = sorted(set(runs.cases) & set(earlier.cases))
    if not shared:
        return f"not comparable: the previous sweep graded none of {', '.join(sorted(runs.cases))}"
    before, before_total = violating(earlier.by_condition["skill"], shared)
    if shared == sorted(runs.cases) == sorted(earlier.cases):
        now, _ = violating(runs.by_condition["skill"])
        return f"was {before} of {before_total}: {change(before, now)}"
    now, total = violating(runs.by_condition["skill"], shared)
    return f"over {', '.join(shared)} only: {now} of {total}, was {before} of {before_total}: {change(before, now)}"


def cull_sections(baseline, previous):
    unconfirmed_now = (
        "Unconfirmed (Opus or Sonnet never produced the construct the rule governs):",
        [value_line(rule, cases, per_tier) for rule, (cases, per_tier) in baseline.items() if unconfirmed(per_tier)],
    )
    if not previous:
        return [
            ("Candidates (Opus and Sonnet exercised the rule and neither violated it):",
             [candidate_line(rule, cases, per_tier) for rule, (cases, per_tier) in baseline.items() if candidate(per_tier)]),
            unconfirmed_now,
        ]
    earlier = [rule for rule, runs in previous.items() if candidate(runs.by_condition["baseline"]) and rule in baseline]
    violated_now = [rule for rule in earlier if dropped(baseline[rule][1])]
    confirmed = [rule for rule in earlier if candidate(baseline[rule][1])]
    return [
        ("Confirmed (a candidate in both sweeps):",
         [candidate_line(rule, *baseline[rule]) for rule in confirmed]),
        ("Dropped (a candidate the previous sweep had; Opus or Sonnet violated it in this one):",
         [value_line(rule, *baseline[rule]) for rule in violated_now]),
        ("Unconfirmed (a candidate the previous sweep had; Opus or Sonnet did not exercise it this time):",
         [value_line(rule, *baseline[rule]) for rule in earlier if rule not in confirmed and rule not in violated_now]),
        ("New candidates (clean on Opus and Sonnet this sweep, not a candidate before):",
         [candidate_line(rule, cases, per_tier) for rule, (cases, per_tier) in baseline.items()
          if candidate(per_tier) and rule not in earlier]),
        unconfirmed_now,
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("grades", type=pathlib.Path, help="the sweep's grades folder")
    parser.add_argument("--readme", type=pathlib.Path, default=README, help="the README whose rule index names each rule's cases")
    parser.add_argument("--previous", type=pathlib.Path, help="the previous sweep's grades folder, for the cull lists and per-rule change")
    args = parser.parse_args()
    rows = index_rows(args.readme.read_text())
    table, problems, notes = collect(load_grades(args.grades), rows)
    if problems:
        for problem in problems:
            print("refused:", problem, file=sys.stderr)
        return 1
    for note in notes:
        print("note:", note, file=sys.stderr)
    previous, _, previous_notes = collect(load_grades(args.previous), rows) if args.previous else ({}, [], [])
    for note in previous_notes:
        print("note (previous sweep):", note, file=sys.stderr)

    for row in rows:
        value = column(table[row.rule].by_condition["baseline"]) if row.rule in table else "not provocable"
        print(row.with_value(value))

    print("\nRuns violating each rule, summed over its cases:")
    for rule, runs in table.items():
        parts = ["without skill {} of {}".format(*violating(runs.by_condition["baseline"]))]
        if runs.by_condition["skill"]:
            now, total = violating(runs.by_condition["skill"])
            parts.append(f"with skill {now} of {total}")
            if rule in previous and previous[rule].by_condition["skill"]:
                parts.append(comparison(runs, previous[rule]))
        print(f"- {rule}: {'; '.join(parts)}")

    baseline = {rule: (runs.cases, runs.by_condition["baseline"]) for rule, runs in table.items()}
    for title, lines in cull_sections(baseline, previous):
        print(f"\n{title}")
        for line in sorted(lines) or ["- none"]:
            print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
