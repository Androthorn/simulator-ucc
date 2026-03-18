"""Generate publication-quality graphs for ADRS experiment analysis.

Produces two figures:
1. Per-run metric breakdown for the best model (gemini t=0.1)
2. Cross-model composite score comparison (box plot + strip plot)

Usage:
    python3 generate_graphs.py --csv combined_summaries.csv --out ./figures/
"""

import argparse
import csv
import os
from collections import defaultdict
from pathlib import Path

import matplotlib.pyplot as plt
import matplotlib.ticker as mticker
import numpy as np


# --- Scoring constants (must match adrs evaluator) ---
BASELINES = {
    "pending_pods": 100.0,
    "time_with_pending": 1.0,
    "cost": 0.1,
    "number_of_migrations": 200.0,
}
WEIGHTS = {
    "pending_pods": 0.35,
    "time_with_pending": 0.25,
    "cost": 0.25,
    "number_of_migrations": 0.15,
}
SCORED_METRICS = list(BASELINES.keys())


def normalize(value: float, baseline: float) -> float:
    """Target-based normalization: s = max(0, 1 - v/b)."""
    return max(0.0, 1.0 - value / baseline)


def composite_score(metrics: dict[str, float]) -> float:
    """Weighted average of normalized scores."""
    total = 0.0
    for m in SCORED_METRICS:
        if m in metrics:
            total += WEIGHTS[m] * normalize(metrics[m], BASELINES[m])
    return total


def load_data(csv_path: str) -> dict:
    """Load and group CSV data by (model, threshold, run_number)."""
    grouped = defaultdict(dict)  # (model, threshold, run) -> {metric: mean}
    with open(csv_path, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            model = row.get("model", "").strip()
            threshold = row.get("threshold", "").strip()
            run_number = row.get("run_number", "").strip()
            metric = row.get("metric", "").strip()
            if not all([model, threshold, run_number, metric]):
                continue
            try:
                mean_val = float(row["mean"])
                grouped[(model, threshold, int(run_number))][metric] = mean_val
            except (ValueError, KeyError):
                continue
    return grouped


def short_name(model: str) -> str:
    """Shorten model names for axis labels."""
    mapping = {
        "google-gemini-2.5-flash": "Gemini 2.5 Flash",
        "openai-gpt-5": "GPT-5",
        "openai-gpt-5-mini": "GPT-5 Mini",
        "anthropic-claude-haiku-4.5": "Claude Haiku 4.5",
    }
    return mapping.get(model, model)


def plot_per_run_metrics(grouped: dict, out_dir: Path, model: str, threshold: str,
                         max_run: int = 10):
    """Graph 1: Per-run metric breakdown for one model configuration."""
    runs = {}
    for (m, t, r), metrics in grouped.items():
        if m == model and t == threshold and r <= max_run:
            runs[r] = metrics

    if not runs:
        print(f"No data for {model} t={threshold} runs 1-{max_run}")
        return

    run_numbers = sorted(runs.keys())

    # Compute normalized scores per metric per run
    metric_labels = {
        "pending_pods": "Pending Pods (w=0.35)",
        "time_with_pending": "Time with Pending (w=0.25)",
        "cost": "Cost (w=0.25)",
        "number_of_migrations": "Migrations (w=0.15)",
    }
    colors = {
        "pending_pods": "#2196F3",
        "time_with_pending": "#FF9800",
        "cost": "#4CAF50",
        "number_of_migrations": "#9C27B0",
    }

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(10, 8), sharex=True,
                                     gridspec_kw={"height_ratios": [2, 1]})

    # Top panel: normalized scores per metric
    for metric in SCORED_METRICS:
        scores = [normalize(runs[r].get(metric, 0), BASELINES[metric])
                  for r in run_numbers]
        ax1.plot(run_numbers, scores, marker="o", linewidth=2, markersize=6,
                 label=metric_labels[metric], color=colors[metric], alpha=0.85)

    ax1.set_ylabel("Normalized Score  $s_i = \\max(0,\\, 1 - v_i / b_i)$",
                   fontsize=11)
    ax1.set_title(
        f"Per-Run Metric Scores — {short_name(model)} (T={threshold})",
        fontsize=13, fontweight="bold", pad=12,
    )
    ax1.legend(loc="lower left", fontsize=9, framealpha=0.9)
    ax1.set_ylim(-0.05, 1.05)
    ax1.grid(True, alpha=0.3)
    ax1.axhline(y=0.5, color="gray", linestyle="--", alpha=0.4)

    # Bottom panel: composite score
    composites = [composite_score(runs[r]) for r in run_numbers]
    mean_c = np.mean(composites)
    ax2.bar(run_numbers, composites, color="#1565C0", alpha=0.75, edgecolor="white")
    ax2.axhline(y=mean_c, color="#D32F2F", linestyle="--", linewidth=1.5,
                label=f"Mean = {mean_c:.4f}")
    ax2.set_xlabel("Run Number", fontsize=11)
    ax2.set_ylabel("Composite Score", fontsize=11)
    ax2.set_ylim(0, max(composites) * 1.15)
    ax2.xaxis.set_major_locator(mticker.MaxNLocator(integer=True))
    ax2.legend(loc="lower left", fontsize=9)
    ax2.grid(True, alpha=0.3, axis="y")

    plt.tight_layout()
    fname = out_dir / f"per_run_metrics_{model}_t{threshold}.png"
    fig.savefig(fname, dpi=150, bbox_inches="tight")
    print(f"Saved: {fname}")
    plt.close(fig)


def plot_model_comparison(grouped: dict, out_dir: Path, max_run: int = 10):
    """Graph 2: Cross-model composite score comparison (box + strip)."""
    # Group composite scores by (model, threshold)
    agent_scores = defaultdict(list)
    for (model, threshold, run), metrics in grouped.items():
        if run <= max_run:
            agent_scores[(model, threshold)].append(composite_score(metrics))

    if not agent_scores:
        print("No data for model comparison")
        return

    # Sort by mean score descending
    sorted_agents = sorted(agent_scores.items(),
                           key=lambda x: np.mean(x[1]), reverse=True)

    labels = []
    data = []
    means = []
    for (model, threshold), scores in sorted_agents:
        labels.append(f"{short_name(model)}\n(T={threshold})")
        data.append(scores)
        means.append(np.mean(scores))

    fig, ax = plt.subplots(figsize=(12, 6))

    # Box plot
    bp = ax.boxplot(data, patch_artist=True, widths=0.5,
                    medianprops=dict(color="black", linewidth=1.5),
                    whiskerprops=dict(linewidth=1.2),
                    capprops=dict(linewidth=1.2))

    # Color palette
    palette = ["#1565C0", "#1976D2", "#43A047", "#F57C00",
               "#E53935", "#8E24AA", "#00897B", "#5C6BC0"]

    for i, patch in enumerate(bp["boxes"]):
        color = palette[i % len(palette)]
        patch.set_facecolor(color)
        patch.set_alpha(0.6)

    # Strip plot (individual points)
    rng = np.random.default_rng(42)
    for i, scores in enumerate(data):
        jitter = rng.uniform(-0.12, 0.12, size=len(scores))
        ax.scatter(np.full(len(scores), i + 1) + jitter, scores,
                   color=palette[i % len(palette)], alpha=0.7, s=30,
                   edgecolor="white", linewidth=0.5, zorder=3)

    # Mean markers
    for i, m in enumerate(means):
        ax.scatter(i + 1, m, color="red", marker="D", s=60, zorder=4,
                   edgecolor="white", linewidth=1)

    ax.set_xticklabels(labels, fontsize=9)
    ax.set_ylabel("Composite Score", fontsize=12)
    ax.set_title(
        "Cross-Model Comparison — Composite Scores (10 runs each)",
        fontsize=13, fontweight="bold", pad=12,
    )
    ax.grid(True, alpha=0.3, axis="y")

    # Add legend for mean marker
    from matplotlib.lines import Line2D
    legend_elements = [
        Line2D([0], [0], marker="D", color="w", markerfacecolor="red",
               markersize=8, label="Mean"),
        Line2D([0], [0], marker="o", color="w", markerfacecolor="gray",
               markersize=6, label="Individual runs"),
    ]
    ax.legend(handles=legend_elements, loc="upper right", fontsize=9)

    plt.tight_layout()
    fname = out_dir / "model_comparison_boxplot.png"
    fig.savefig(fname, dpi=150, bbox_inches="tight")
    print(f"Saved: {fname}")
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser(description="Generate ADRS experiment graphs")
    parser.add_argument("--csv", required=True, help="Path to combined_summaries.csv")
    parser.add_argument("--out", default="./figures", help="Output directory")
    parser.add_argument("--best-model", default="google-gemini-2.5-flash")
    parser.add_argument("--best-temp", default="0.1")
    parser.add_argument("--max-run", type=int, default=10,
                        help="Max run number to include (for v1 baseline)")
    args = parser.parse_args()

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    print("Loading data...")
    grouped = load_data(args.csv)
    print(f"Loaded {len(grouped)} runs\n")

    print("Generating per-run metrics graph...")
    plot_per_run_metrics(grouped, out_dir, args.best_model, args.best_temp,
                         args.max_run)

    print("\nGenerating cross-model comparison graph...")
    plot_model_comparison(grouped, out_dir, args.max_run)

    print("\nDone!")


if __name__ == "__main__":
    main()
