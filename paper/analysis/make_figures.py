#!/usr/bin/env python3
"""Gera TODAS as figuras finais do paper (n=80) de uma vez, deterministicamente.

Fontes de dado (unicas):
  analysis/new_runs_scored.csv        -> FIG 2, FIG 3, braco 'observed' da FIG 4
  analysis/replay_promotion_by_n.csv  -> FIG 1
  analysis/old_gemini_labeled.csv     -> FIG 5 (trajetoria v1..v6), braco 'pilot' da FIG 4
  simulatormeu/runs-workshop/experimento/experimento_summary.csv -> FIG 6 (ao vivo)

Saida: modular/figures/*.pdf (vetorial, fonte embutida, sem titulo embutido).
Estilo: brief instrucoes.md (Okabe-Ito, azul=p0, laranja=p4). Seed 20260717.

Rode:  python3 analysis/make_figures.py
"""

from pathlib import Path

import numpy as np
import pandas as pd
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from scipy import stats

SEED = 20260717
HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
OUT = ROOT / "figures"
OUT.mkdir(parents=True, exist_ok=True)

# ── paleta Okabe-Ito (hex exatos do brief) ────────────────────────────────────
BASE = "#0072B2"   # p0 / baseline (azul)
REFINED = "#E69F00"  # p4 / refinado (laranja)
THIRD = "#009E73"  # haiku / 3o grupo (verde)
TAIL = "#D55E00"   # pior / cauda (vermelhao)
REF = "#999999"    # limiar / referencia (cinza)
INK = "#222222"    # tinta neutra (texto/eixos)

COL_W = 3.4        # largura de coluna IEEE (in)

# ── rcParams globais (valem para todas) ───────────────────────────────────────
plt.rcParams.update({
    "font.family": "serif",
    "font.serif": ["STIXGeneral", "DejaVu Serif"],
    "mathtext.fontset": "stix",
    "font.size": 8,
    "axes.labelsize": 8,
    "legend.fontsize": 7,
    "xtick.labelsize": 7,
    "ytick.labelsize": 7,
    "axes.linewidth": 0.8,
    "lines.linewidth": 1.3,
    "text.color": INK,
    "axes.labelcolor": INK,
    "axes.edgecolor": INK,
    "xtick.color": INK,
    "ytick.color": INK,
    "pdf.fonttype": 42,   # embute TrueType
    "ps.fonttype": 42,
})


def clean(ax):
    """Remove spines top/right — padrao do brief."""
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)


def save(fig, name):
    p = OUT / name
    fig.savefig(p, bbox_inches="tight", pad_inches=0.02)
    plt.close(fig)
    print(f"[ok] {p.relative_to(ROOT)}")


# ── dados ─────────────────────────────────────────────────────────────────────
NEW = pd.read_csv(HERE / "new_runs_scored.csv")
REPLAY = pd.read_csv(HERE / "replay_promotion_by_n.csv").set_index("candidate")
REAL = pd.read_csv(HERE / "real_gain_promotion_by_k.csv")   # gate sob ganho real (A1 x B1)
OLD = pd.read_csv(HERE / "old_gemini_labeled.csv")
LIVE = pd.read_csv(ROOT / "data" / "runs-workshop" / "experimento"
                   / "experimento_summary.csv")

D_MIN = 0.05       # margem do gate corrigido (pre-registro)
ALPHA = 0.05       # unilateral (pre-registro §4b)
EPS_LEGACY = 1.0   # epsilon_k da regra antiga (hefesto/core/loop.py)


def blk(b):
    return NEW[NEW.bloco == b].S.values


# ══════════════════════════════════════════════════════════════════════════════
# FIG 1 — promotion_by_n.pdf : promover por 1 execucao e uma moeda; n corrige.
# ══════════════════════════════════════════════════════════════════════════════
def fig1():
    ns = [1, 2, 3, 5, 10]
    cols = [f"p_promote_n{n}" for n in ns]
    series = [
        ("v5", "identical", INK, "-", "o"),
        ("v3", "truly worse", TAIL, "-", "s"),
        ("v6", "truly better", THIRD, "-", "^"),
    ]
    fig, ax = plt.subplots(figsize=(COL_W, 2.4))
    ax.axhline(0.5, color=REF, ls="--", lw=0.9, zorder=1)
    ax.text(9.6, 0.512, "coin flip", color=REF, fontsize=7, ha="right", va="bottom")

    for cand, label, color, ls, mk in series:
        y = REPLAY.loc[cand, cols].astype(float).values
        ax.plot(ns, y, ls=ls, marker=mk, ms=3.5, color=color, label=label, zorder=3)

    # gate corrigido sob um ganho real (A1 x B1, troca de modelo, d=1.59):
    # tracejada + marcador proprio para distinguir em P&B das solidas do regime naive
    ax.plot(REAL.k, REAL.gate, ls="--", marker="D", ms=3, color=BASE,
            label="corrected gate, real gain", zorder=3)

    ax.set_xscale("log")
    ax.set_xticks(ns)
    ax.set_xticklabels([str(n) for n in ns])
    ax.tick_params(axis="x", which="minor", bottom=False)
    ax.set_xlim(0.9, 11)
    ax.set_ylim(0, 1.0)
    ax.set_xlabel("Evaluation runs per candidate")
    ax.set_ylabel("P(promotion)")
    ax.axvline(1, color=REF, ls=":", lw=0.7, zorder=1)
    ax.text(1.03, 0.97, "n=1", color=REF, fontsize=6.5, ha="left", va="top")
    ax.legend(frameon=False, loc="lower center", ncol=2, handlelength=1.5,
              columnspacing=1.2, borderaxespad=0.2)
    clean(ax)
    save(fig, "promotion_by_n.pdf")


# ══════════════════════════════════════════════════════════════════════════════
# FIG 2 — intermodel_dist.pdf : modelo >> prompt (gemini p0 x haiku p0).
# ══════════════════════════════════════════════════════════════════════════════
def fig2():
    a1, b1 = blk("A1"), blk("B1")
    groups = [("gemini", a1, BASE), ("haiku", b1, THIRD)]
    rng = np.random.default_rng(SEED)

    fig, ax = plt.subplots(figsize=(COL_W, 2.4))
    for i, (name, v, color) in enumerate(groups):
        x = i + rng.uniform(-0.09, 0.09, len(v))
        ax.scatter(x, v, s=10, color=color, alpha=0.6, edgecolors="none", zorder=3)
        bp = ax.boxplot(v, positions=[i], widths=0.34, showfliers=False,
                        patch_artist=False, zorder=2)
        for part in ("boxes", "whiskers", "caps", "medians"):
            for art in bp[part]:
                art.set_color(INK)
                art.set_linewidth(0.9)

    # d de Cohen e Welch p, recomputados do dado (autoconsistente)
    nx, ny = len(a1), len(b1)
    sp = np.sqrt(((nx - 1) * a1.var(ddof=1) + (ny - 1) * b1.var(ddof=1)) / (nx + ny - 2))
    d = (a1.mean() - b1.mean()) / sp
    _, p = stats.ttest_ind(a1, b1, equal_var=False)
    ax.text(0.03, 0.03, f"$d={d:.2f}$,  $p={p:.3f}$", transform=ax.transAxes,
            fontsize=7, color=INK, ha="left", va="bottom")

    ax.set_xticks([0, 1])
    ax.set_xticklabels([f"gemini\n(n={nx})", f"haiku\n(n={ny})"])
    ax.set_xlim(-0.5, 1.5)
    ax.set_ylim(0.3, 0.8)
    ax.set_ylabel("Stability score $S$")
    clean(ax)
    save(fig, "intermodel_dist.pdf")


# ══════════════════════════════════════════════════════════════════════════════
# FIG 3 — mixture_blocks.pdf : 3 modos (plato/meio/cauda); prompt+modelo movem
#         o peso, nao os componentes. Quatro blocos.
# ══════════════════════════════════════════════════════════════════════════════
def fig3():
    # (bloco, x, cor) — gemini a esquerda, haiku a direita, com respiro no meio
    specs = [
        ("A1", 0.0, BASE),      # gemini p0
        ("A2", 1.0, REFINED),   # gemini p4
        ("B1", 2.6, BASE),      # haiku p0
        ("B2", 3.6, REFINED),   # haiku p4
    ]
    labels = [r"gemini $p_0$", r"gemini $p_4$", r"haiku $p_0$", r"haiku $p_4$"]
    rng = np.random.default_rng(SEED)

    fig, ax = plt.subplots(figsize=(COL_W, 2.5))
    # linhas-guia dos modos plato/cauda
    for yv in (0.75, 0.40):
        ax.axhline(yv, color=REF, ls=":", lw=0.7, zorder=1)

    for (b, x, color), lab in zip(specs, labels):
        v = blk(b)
        xj = x + rng.uniform(-0.13, 0.13, len(v))
        ax.scatter(xj, v, s=10, color=color, alpha=0.6, edgecolors="none", zorder=3)
        med = np.median(v)
        ax.plot([x - 0.22, x + 0.22], [med, med], color=REF, lw=1.6, zorder=4)

    ax.set_xticks([s[1] for s in specs])
    ax.set_xticklabels([f"{lab}\n(n={len(blk(s[0]))})" for s, lab in zip(specs, labels)])
    ax.set_xlim(-0.5, 4.1)
    ax.set_ylim(0.3, 0.8)
    ax.set_ylabel("Stability score $S$")
    clean(ax)
    save(fig, "mixture_blocks.pdf")


# ══════════════════════════════════════════════════════════════════════════════
# FIG 4 — power_curves.pdf : poder para media (Welch) e variancia (Levene) sob o
#         efeito do PILOTO (linha cheia) vs OBSERVADO (pontilhada). Monte-Carlo.
#         pilot:    v1 (n=10) vs v5=runs38-47 (n=10)  [efeito otimista do piloto]
#         observed: A1 gemini p0 vs A2 gemini p4 (n=30) [efeito fresco]
# ══════════════════════════════════════════════════════════════════════════════
def fig4():
    v1 = OLD[OLD.prompt_file == "consolidator_agent"].S.values
    v5 = OLD[(OLD.prompt_file == "consolidator_agent_v5") & (OLD.run.between(38, 47))].S.values
    a1, a2 = blk("A1"), blk("A2")
    scen = {
        "pilot": ((v1.mean(), v1.std(ddof=1)), (v5.mean(), v5.std(ddof=1)), "-"),
        "observed": ((a1.mean(), a1.std(ddof=1)), (a2.mean(), a2.std(ddof=1)), "--"),
    }
    n_grid = np.array([10, 15, 20, 30, 45, 60, 80, 100, 120])
    B = 2000
    rng = np.random.default_rng(SEED)

    def power(g0, g1, n, test):
        hits = 0
        for _ in range(B):
            x = rng.normal(g0[0], g0[1], n)
            y = rng.normal(g1[0], g1[1], n)
            if test == "welch":
                _, p = stats.ttest_ind(x, y, equal_var=False)
            else:
                _, p = stats.levene(x, y, center="median")
            hits += p < 0.05
        return hits / B

    fig, ax = plt.subplots(figsize=(COL_W, 2.4))
    ax.axhline(0.8, color=REF, ls="--", lw=0.9, zorder=1)
    ax.text(118, 0.815, "0.8", color=REF, fontsize=7, ha="right", va="bottom")
    curves = [("welch", BASE, "Welch (mean)"), ("levene", REFINED, "Levene (var.)")]
    for test, color, base_lab in curves:
        for sname, (g0, g1, ls) in scen.items():
            yv = [power(g0, g1, int(n), test) for n in n_grid]
            lab = f"{base_lab.split()[0]} {sname}"
            ax.plot(n_grid, yv, ls=ls, color=color, marker="o", ms=2.5, label=lab, zorder=3)

    ax.set_xlim(8, 122)
    ax.set_ylim(0, 1)
    ax.set_xlabel("Runs per arm")
    ax.set_ylabel("Power")
    ax.legend(frameon=False, loc="center right", handlelength=1.9, fontsize=6.5)
    clean(ax)
    save(fig, "power_curves.pdf")


# ══════════════════════════════════════════════════════════════════════════════
# FIG 5 — trajectory_gate.pdf : trajetoria p0..p5 com IC95%, contra a banda do
#         gate (baseline p0 +/- limiar). Nada cruza por margem significativa.
#         Banda = p0_mean +/- pstdev(p0)  (visual do gate eps_k=1, 1-sigma).
# ══════════════════════════════════════════════════════════════════════════════
def fig5():
    order = ["consolidator_agent", "consolidator_agent_v2", "consolidator_agent_v3",
             "consolidator_agent_v4", "consolidator_agent_v5", "consolidator_agent_v6"]
    labels = [r"$p_0$", r"$p_1$", r"$p_2$", r"$p_3$", r"$p_4$", r"$p_5$"]
    means, cis = [], []
    for pf in order:
        v = OLD[OLD.prompt_file == pf].S.values
        means.append(v.mean())
        cis.append(1.96 * v.std(ddof=1) / np.sqrt(len(v)))
    means, cis = np.array(means), np.array(cis)
    x = np.arange(len(order))

    p0 = OLD[OLD.prompt_file == order[0]].S.values
    half = p0.std(ddof=0)  # limiar visual do gate (1-sigma do baseline)
    lo, hi = means[0] - half, means[0] + half

    fig, ax = plt.subplots(figsize=(COL_W, 2.5))
    ax.axhspan(lo, hi, color=REF, alpha=0.15, zorder=1)
    ax.axhline(means[0], color=REF, ls="--", lw=0.8, zorder=1)
    ax.errorbar(x, means, yerr=cis, fmt="o-", color=BASE, ms=4, capsize=2,
                lw=1.3, elinewidth=1.0, zorder=3)
    # destaque discreto p4 (vencedor historico) e p5 (curiosidade)
    ax.annotate("winner", (x[4], means[4]), textcoords="offset points",
                xytext=(0, 9), ha="center", fontsize=6.5, color=REFINED)
    ax.annotate("later", (x[5], means[5]), textcoords="offset points",
                xytext=(4, 6), ha="left", fontsize=6.5, color=INK)

    ax.set_xticks(x)
    ax.set_xticklabels(labels)
    ax.set_xlim(-0.4, 5.4)
    ax.set_ylim(0.45, 0.80)
    ax.set_ylabel("Stability score $S$")
    ax.set_xlabel("Refinement step")
    clean(ax)
    save(fig, "trajectory_gate.pdf")


# ══════════════════════════════════════════════════════════════════════════════
# FIG 6 — false_promotion_by_rule.pdf : taxa de falsa promocao das 3 regras sob
#         o nulo, por k. Nulo exato: os dois bracos sao sorteados do mesmo pool
#         p0 U p0' (mesmo prompt). Analise 1 do pre-registro.
# ══════════════════════════════════════════════════════════════════════════════
def fig6():
    pool = LIVE[LIVE.arm.isin(["p0", "p0_prime"])].S.values
    ks = np.array([1, 2, 3, 4, 6, 8, 10, 12])   # 2k <= 24 (bracos disjuntos)
    B = 40000
    rng = np.random.default_rng(SEED)

    def rates(k):
        """Divisoes disjuntas das 24 nulas em dois bracos de k (pre-registro §4a)."""
        idx = np.argsort(rng.random((B, len(pool))), axis=1)
        s = pool[idx]
        x, y = s[:, :k], s[:, k:2 * k]
        delta = y.mean(1) - x.mean(1)

        naive = delta > 0
        # legacy: pareada por zip, sigma = pstdev dos deltas (em k=1 degenera em delta>0)
        d = y - x
        eps = d.mean(1) > EPS_LEGACY * d.std(1, ddof=0)
        # gate: LB de IC Welch unilateral sobre o ganho, contra a margem d_min
        if k > 1:
            vx, vy = x.var(1, ddof=1), y.var(1, ddof=1)
            se = np.sqrt(vx / k + vy / k)
            df = (vx / k + vy / k) ** 2 / ((vx / k) ** 2 + (vy / k) ** 2) * (k - 1)
            gate = float((delta - stats.t.ppf(1 - ALPHA, df) * se > D_MIN).mean())
        else:
            gate = np.nan   # sem variancia intra-braco o gate nao e definido
        return naive.mean(), eps.mean(), gate

    y = np.array([rates(int(k)) for k in ks])

    fig, ax = plt.subplots(figsize=(COL_W, 2.5))
    ax.axhline(0.5, color=REF, ls="--", lw=0.9, zorder=1)
    ax.text(12, 0.55, "coin flip", color=REF, fontsize=6.5, ha="right", va="bottom")
    ax.axhline(0.05, color=REF, ls=":", lw=0.9, zorder=1)
    ax.text(12, 0.056, r"nominal $\alpha$", color=REF, fontsize=6.5, ha="right", va="bottom")

    series = [(0, TAIL, "o", 4.5, 3, "naive"),
              (1, REFINED, "s", 3.0, 4, r"legacy $\varepsilon\sigma$"),
              (2, BASE, "^", 3.5, 3, "corrected gate")]
    for j, color, mk, ms, z, label in series:
        ax.plot(ks, y[:, j], marker=mk, ms=ms, color=color, label=label, zorder=z)

    # em k=1 as duas regras antigas degeneram no mesmo criterio (delta>0): e o n
    # que o ADRS operava.
    ax.axvline(1, color=REF, ls=":", lw=0.7, zorder=1)
    ax.annotate("ADRS ran here: both old rules coincide", (1, 0.62),
                textcoords="offset points", xytext=(5, 0), ha="left", va="center",
                fontsize=6.5, color=INK)

    ax.set_yscale("log")
    ax.set_ylim(1e-4, 1)
    ax.set_xlim(0.55, 12.8)
    ax.set_xticks(ks)
    ax.set_xlabel("Replicas per candidate $k$")
    ax.set_ylabel("False-promotion rate")
    ax.legend(frameon=False, loc="lower left", handlelength=1.6, fontsize=6.5)
    clean(ax)
    save(fig, "false_promotion_by_rule.pdf")


def main():
    fig1()
    fig2()
    fig3()
    fig4()
    fig5()
    fig6()
    print(f"\n6 figuras -> {OUT.relative_to(ROOT)}/")


if __name__ == "__main__":
    main()
