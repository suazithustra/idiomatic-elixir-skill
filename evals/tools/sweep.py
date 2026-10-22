"""Run a matrix of cases, conditions and models through run.py, five sessions at a time.
The default matrix is a full sweep: every case, baseline then skill, Opus once and Haiku and
Sonnet twice each. A check batch is a subset: one case, the skill condition, no Opus."""
import argparse
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

import run as runner
from common import CONDITIONS, PARALLEL, SWEEP_RUNS

DEFAULT_MATRIX = ",".join(f"{model}={count}" for model, count in SWEEP_RUNS.items())


def parse_matrix(spec):
    matrix = []
    for entry in spec.split(","):
        model, _, count = entry.partition("=")
        matrix.append((model, int(count or 1)))
    return matrix


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cases", help="comma-separated subset of cases; every case file by default")
    parser.add_argument("--conditions", default=",".join(CONDITIONS), help="comma-separated, run in this order")
    parser.add_argument("--models", default=DEFAULT_MATRIX, help="comma-separated identifier=runs")
    runner.add_common_arguments(parser)
    args = parser.parse_args()
    setup = runner.setup_from(args)
    cases = args.cases.split(",") if args.cases else sorted(p.stem for p in setup.cases_dir.glob("*.md"))
    conditions = args.conditions.split(",")
    runner.refuse_if_installed(setup.skills_folder, setup.skill_dir)
    matrix = parse_matrix(args.models)
    jobs = [
        (case, condition, model, n)
        for case in cases
        for condition in conditions
        for model, count in matrix
        for n in range(1, count + 1)
    ]
    if args.dry_run:
        for job in jobs:
            runner.describe(setup, *job)
        return
    with runner.extras_hidden() as hidden:
        return run_jobs(setup, jobs, hidden)


def run_jobs(setup, jobs, hidden):
    with open(setup.run_root / "progress.log", "a") as log:
        def note(message):
            line = f"{time.strftime('%H:%M:%S')} {message}"
            print(line, flush=True)
            log.write(line + "\n")
            log.flush()

        note(f"run root {setup.run_root}; output {setup.output}; {len(jobs)} runs")
        note("hidden for the sweep: " + (", ".join(hidden) or "nothing"))
        failed, not_clean = 0, []
        pool = ThreadPoolExecutor(max_workers=PARALLEL)
        futures = {pool.submit(runner.run_one, setup, *job): job for job in jobs}
        try:
            for future in as_completed(futures):
                try:
                    rid, rc = future.result()
                except Exception as exc:
                    failed += 1
                    case, condition, model, n = futures[future]
                    note(f"failed {case}/{condition}-{model}-{n}: {exc!r}")
                else:
                    note(f"done {rid} rc={rc}")
                    if rc not in (0, "exists"):
                        not_clean.append(f"{rid} rc={rc}")
        except KeyboardInterrupt:
            pool.shutdown(wait=False, cancel_futures=True)
            runner.stop_sessions()
            note("interrupted; the runs that were in progress are not kept and start again on resume")
            return 130
        pool.shutdown()
        note("all done" + (f"; runs to look at: {', '.join(not_clean)}" if not_clean else ""))
        return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
