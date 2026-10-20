#!/usr/bin/env python3
"""Which version of the p4 prompt did runs 34-37 run? (paper, Section V-B)

The few-shot prompt p4 (file consolidator_agent_v5.txt in Phase 2) has three
examples. ADRS generated two (adrs.db, prompt 4); the third, "Workload Already
on Public with No Pending Pods", was added by hand and is where the word
"churn" first enters the prompts. The run configuration records only the
prompt's file name, so this script counts "churn" in each run's logged agent
explanations instead.

Two modes:
  churn_marker.py --from-csv          summary from the committed churn_by_run.csv
  churn_marker.py --old-runs DIR --runs DIR
                                      recount from the raw runs (Zenodo archive)
                                      and rewrite churn_by_run.csv

Raw layout expected (as in the archive): DIR/old_runs = the
google-gemini-2.5-flash_input_const_v2_0.1_runN directories; DIR/runs = the
A1, A2, B1, B2 block directories.
"""
import argparse
import csv
import re
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
OUT = HERE / "churn_by_run.csv"
WORD = re.compile(rb"churn", re.IGNORECASE)


def count(run_dir: Path) -> int:
    return sum(len(WORD.findall(f.read_bytes())) for f in run_dir.rglob("*") if f.is_file())


def recount(old_runs: Path, runs: Path) -> list[dict]:
    rows = []
    for d in sorted(old_runs.glob("google-gemini-2.5-flash_input_const_v2_0.1_run*")):
        cfg = (d / "config_used.yaml").read_text(errors="replace")
        m = re.search(r"consolidator_prompt_file:\s*(\S+)", cfg)
        rows.append({"window": "phase2-2026-03", "run": d.name, "prompt": m.group(1) if m else "",
                     "churn": count(d)})
    for block in ["A1", "A2", "B1", "B2"]:
        for d in sorted((runs / block).glob("*/")):
            rows.append({"window": "confirmatory-2026-07", "run": f"{block}/{d.name}",
                         "prompt": {"A1": "p0 gemini", "A2": "p4 gemini",
                                    "B1": "p0 haiku", "B2": "p4 haiku"}[block],
                         "churn": count(d)})
    with OUT.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["window", "run", "prompt", "churn"])
        w.writeheader()
        w.writerows(rows)
    return rows


def summary(rows: list[dict]) -> None:
    groups = defaultdict(list)
    for r in rows:
        prompt, run = r["prompt"], r["run"]
        if prompt == "consolidator_agent_v5":
            n = int(run.rsplit("run", 1)[1])
            prompt = "v5 runs 34-37" if n <= 37 else "v5 runs 38-47"
        groups[(r["window"], prompt)].append(int(r["churn"]))
    print(f"{'window':22s} {'prompt':26s} {'runs':>4s} {'with churn':>10s}")
    for (window, prompt), c in sorted(groups.items()):
        print(f"{window:22s} {prompt:26s} {len(c):4d} {sum(x > 0 for x in c):10d}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--from-csv", action="store_true")
    ap.add_argument("--old-runs", type=Path, default=REPO / "old_runs")
    ap.add_argument("--runs", type=Path, default=REPO / "runs")
    a = ap.parse_args()
    if a.from_csv:
        with OUT.open() as f:
            rows = list(csv.DictReader(f))
    else:
        rows = recount(a.old_runs, a.runs)
    summary(rows)


if __name__ == "__main__":
    main()
