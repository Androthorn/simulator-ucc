#!/usr/bin/env python3
"""Replay retrospectivo: o gate de promocao do hefesto novo aplicado a v1->v6.

Pergunta: dado o gate atual (hefesto/core/loop.py, linha 87)
    promove se  delta > epsilon_k * pooled_std   (epsilon_k default = 1.0)
o que teria sido promovido na trajetoria v1..v6? E com que facilidade o regime
antigo (avaliacao de 1 execucao) promovia por PURO RUIDO?

ADAPTACAO DECLARADA: o hefesto usa pstdev de deltas PAREADOS. Os runs antigos
sao independentes e de tamanhos diferentes (v3 n=10, v5 n=14) -> nao ha pareamento.
Adaptamos para diferenca de medias com dois denominadores, e reportamos os dois:
  (A) SE_welch = sqrt(var_c/n_c + var_p/n_p)   -- erro padrao da diferenca (o brief)
  (B) SD_pool  = sqrt((var_c*(n_c-1)+var_p*(n_p-1))/(n_c+n_p-2))  -- analogo fiel ao
      pstdev do hefesto (barra de tamanho-de-efeito). SD_pool ~ SE*sqrt(n): barra
      MAIS DURA. Se nem a barra facil (A) promove, a fiel (B) tambem nao.

Fonte unica de score: ucc_scoring.py (CFIXED). Rotulos: config_used.yaml.
Deterministico (seed fixa). Roda em segundos, zero simulacao, zero credito.
"""

import sys
import statistics as st
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).parent))
from ucc_scoring import stability_score, METRICS

DATA = Path(__file__).resolve().parent.parent / "data"   # paper/data, the slim per-run copy
OLD_CSV = DATA / "old_runs" / "outputSummary" / "output" / "combined_summaries.csv"
OLD_RUNS = DATA / "old_runs" / "output"
NEW_RUNS = DATA / "runs"
EPS_DEFAULT = 1.0
EPS_GRID = [0.5, 1.0, 1.5, 2.0]
RNG = np.random.default_rng(20260716)

# trajetoria: nome do arquivo de prompt -> rotulo da versao ADRS
TRAJ = [
    ("consolidator_agent",    "v1"),
    ("consolidator_agent_v2", "v2"),
    ("consolidator_agent_v3", "v3"),
    ("consolidator_agent_v4", "v4"),
    ("consolidator_agent_v5", "v5"),
    ("consolidator_agent_v6", "v6"),
]


def load_old_scores_by_prompt() -> dict:
    """{prompt_file: [S,...]} a partir dos config_used.yaml + combined_summaries."""
    import re
    df = pd.read_csv(OLD_CSV)
    df = df[(df.model == "google-gemini-2.5-flash") & (df.threshold == 0.1)]
    df = df[df.metric.isin(METRICS)]
    out = {}
    for r in range(1, 65):
        cfg = OLD_RUNS / f"google-gemini-2.5-flash_input_const_v2_0.1_run{r}/config_used.yaml"
        if not cfg.exists():
            continue
        m = re.search(r"consolidator_prompt_file:\s*(\S+)", cfg.read_text(errors="replace"))
        if not m:
            continue
        sub = df[df.run_number == r]
        met = dict(zip(sub.metric, sub["mean"]))
        if len(met) == len(METRICS):
            out.setdefault(m.group(1), []).append(stability_score(met))
    return out


def welch_se(c, p):
    return np.sqrt(np.var(c, ddof=1) / len(c) + np.var(p, ddof=1) / len(p))


def pooled_sd(c, p):
    nc, np_ = len(c), len(p)
    return np.sqrt((np.var(c, ddof=1) * (nc - 1) + np.var(p, ddof=1) * (np_ - 1)) / (nc + np_ - 2))


# ── 1. Replay do gate ─────────────────────────────────────────────────────────

def replay(scores):
    print("=" * 90)
    print("1. REPLAY DO GATE NOVO — champion comeca em v1, candidato julgado vs champion VIGENTE")
    print("=" * 90)
    # decisao da epoca: TUDO foi adotado (sem gate) -> champion andou v1->..->v6
    for denom_name, denom in [("SE_welch (brief)", welch_se), ("SD_pool (fiel ao hefesto)", pooled_sd)]:
        print(f"\n--- denominador: {denom_name} ---")
        print(f"{'passo':<10}{'n_c':>4}{'n_p':>4}{'delta':>9}{'denom':>9}{'delta/denom':>12}"
              f"{'  promove? (eps=1.0)':>20}   decisao-epoca")
        champ_label, champ = TRAJ[0][1], scores[TRAJ[0][0]]
        for pf, ver in TRAJ[1:]:
            cand = scores[pf]
            delta = np.mean(cand) - np.mean(champ)
            den = denom(cand, champ)
            ratio = delta / den if den > 0 else float("inf")
            promo = ratio > EPS_DEFAULT
            print(f"{champ_label}->{ver:<5}{len(cand):>4}{len(champ):>4}{delta:>+9.4f}{den:>9.4f}"
                  f"{ratio:>+12.2f}{('  PROMOVE' if promo else '  rejeita'):>20}   adotado (sem gate)")
            if promo:
                champ_label, champ = ver, cand   # so avanca se promoveu
        print(f"    => champion final sob o gate: {champ_label}")

    # sensibilidade em epsilon
    print(f"\n--- sensibilidade: champion final por epsilon_k (denominador SE_welch, o mais permissivo) ---")
    print(f"{'epsilon_k':>10}   champion_final   passos_promovidos")
    for eps in EPS_GRID:
        champ_label, champ = TRAJ[0][1], scores[TRAJ[0][0]]
        promoted = []
        for pf, ver in TRAJ[1:]:
            cand = scores[pf]
            delta = np.mean(cand) - np.mean(champ)
            den = welch_se(cand, champ)
            if den > 0 and delta / den > eps:
                promoted.append(f"{champ_label}->{ver}")
                champ_label, champ = ver, cand
        print(f"{eps:>10.1f}   {champ_label:<15}  {promoted if promoted else '(nenhum)'}")


# ── 2. Contrafactual do regime antigo: P(promocao por ruido) x n ──────────────

def counterfactual(scores):
    print("\n" + "=" * 90)
    print("2. CONTRAFACTUAL DO REGIME ANTIGO — P(promover | avaliacao de n execucoes)")
    print("   champion = v1 (fixo). P = fracao de amostras em que mean(n cand) > mean(n champ).")
    print("   n=1 e a fracao de pares (i,j) com S_cand_j > S_champ_i (Mann-Whitney/CLES).")
    print("=" * 90)
    champ = np.array(scores["consolidator_agent"])  # v1
    ns = [1, 2, 3, 5, 10]
    rows = []
    B = 20000
    print(f"\n{'candidato':<12}{'mean':>8}{'delta_vs_v1':>12}   " + "".join(f"n={n:<7}" for n in ns))
    for pf, ver in TRAJ[1:]:
        cand = np.array(scores[pf])
        delta = cand.mean() - champ.mean()
        ps = []
        for n in ns:
            wins = 0
            for _ in range(B):
                mc = RNG.choice(cand, n, replace=True).mean()
                mp = RNG.choice(champ, n, replace=True).mean()
                wins += mc > mp
            ps.append(wins / B)
        rows.append((ver, cand.mean(), delta, ps))
        print(f"{ver:<12}{cand.mean():>8.3f}{delta:>+12.4f}   " + "".join(f"{p:<9.2f}" for p in ps))
    return rows, ns


# ── 3. Sanidade: o gate nos dados novos A1 vs A2 (n=30) ───────────────────────

def sanity_new():
    print("\n" + "=" * 90)
    print("3. SANIDADE — o gate aplicado a A1 vs A2 (n=30 fresco). Deve dar 'nao promove'.")
    print("=" * 90)
    import json
    def load(bloco):
        out = []
        for d in sorted((NEW_RUNS / bloco).glob("*/")):
            pj = d / "provenance.json"
            if not pj.exists():
                continue
            if json.loads(pj.read_text()).get("status") != "complete":
                continue
            summ = sorted(d.glob("analyzer/summary/summary_metrics_*.csv"))
            if not summ:
                continue
            dd = pd.read_csv(summ[-1], index_col=0)
            met = {m: float(dd.loc[m, "mean"]) for m in METRICS if m in dd.index}
            if len(met) == len(METRICS):
                out.append(stability_score(met))
        return np.array(out)
    a1, a2 = load("A1"), load("A2")
    delta = a2.mean() - a1.mean()
    for nm, den in [("SE_welch", welch_se(a2, a1)), ("SD_pool", pooled_sd(a2, a1))]:
        r = delta / den
        print(f"  A1->A2  n=({len(a1)},{len(a2)})  delta={delta:+.4f}  {nm}={den:.4f}  "
              f"delta/{nm}={r:+.2f}  eps=1.0 -> {'PROMOVE' if r>EPS_DEFAULT else 'nao promove'}")


def write_csv(rows, ns, scores):
    out = Path(__file__).parent / "replay_promotion_by_n.csv"
    with out.open("w") as f:
        f.write("candidate,mean,delta_vs_v1," + ",".join(f"p_promote_n{n}" for n in ns) + "\n")
        for ver, mean, delta, ps in rows:
            f.write(f"{ver},{mean:.4f},{delta:+.4f}," + ",".join(f"{p:.4f}" for p in ps) + "\n")
    print(f"\n[csv] {out}")


def main():
    scores = load_old_scores_by_prompt()
    print("Lotes carregados (rotulo -> n, mean, std):")
    for pf, ver in TRAJ:
        s = scores.get(pf, [])
        print(f"  {ver} ({pf:<24}) n={len(s):>2}  mean={st.mean(s):.4f}  std={st.pstdev(s):.4f}")
    replay(scores)
    rows, ns = counterfactual(scores)
    sanity_new()
    write_csv(rows, ns, scores)


if __name__ == "__main__":
    main()
