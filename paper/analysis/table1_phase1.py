#!/usr/bin/env python3
"""Table I of the paper: Phase 1 stability under the baseline prompt p0.

Ten runs of each model x temperature, scored with the single scoring
function (ucc_scoring) from the per-run means in combined_summaries.csv.
gpt-5-mini at T=0.5 is numbered 11-20 in that file (runs 1-10 under that
label are absent); every other row is runs 1-10.
"""
import sys
from pathlib import Path

import numpy as np
import pandas as pd

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from ucc_scoring import stability_score, METRICS

CSV = HERE.parent / "data" / "old_runs" / "outputSummary" / "output" / "combined_summaries.csv"
FIRST10 = range(1, 11)
ROWS = [("google-gemini-2.5-flash", 0.1, FIRST10), ("google-gemini-2.5-flash", 0.5, FIRST10),
        ("anthropic-claude-haiku-4.5", 0.1, FIRST10), ("anthropic-claude-haiku-4.5", 0.5, FIRST10),
        ("openai-gpt-5-mini", 0.1, FIRST10), ("openai-gpt-5-mini", 0.5, range(11, 21))]


def scores(df, model, temp, runs):
    out = []
    for r in runs:
        sub = df[(df.model == model) & (df.threshold == temp) & (df.run_number == r)]
        m = {k: v for k, v in zip(sub.metric, sub["mean"]) if k in METRICS}
        if len(m) == len(METRICS):
            out.append(stability_score(m))
    return np.array(out)


def main():
    df = pd.read_csv(CSV)
    print(f"{'model':28s} {'T':>4s} {'n':>3s}  mean +- std    min    max")
    for model, temp, runs in ROWS:
        s = scores(df, model, temp, runs)
        print(f"{model:28s} {temp:4.1f} {len(s):3d}  {s.mean():.3f} +- {s.std(ddof=1):.3f}  "
              f"{s.min():.3f}  {s.max():.3f}")


if __name__ == "__main__":
    main()
