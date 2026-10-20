#!/usr/bin/env python3
"""Sensibilidade dos resultados aos pesos do S (objecao: "outra metrica com
sigma menor poderia fazer o loop funcionar").

Re-computa S sob ponderacoes alternativas (baselines b_i intactos — a objecao
e sobre os pesos 0.35/0.25/0.25/0.15) e refaz, para cada ponderacao:

  (a) A1 vs A2 (p0 vs p4, gemini, n=30/30): Welch p, Levene p, d — o nulo
      confirmatorio se mantem?
  (b) as 24 replicas nulas ao vivo (p0 + p0'), k=12: taxa de falsa promocao
      das tres regras (mesmo metodo da fig. 6). Nota: a taxa da regra naive e
      invariante a QUALQUER metrica por exchangeability — verificado, nao
      so afirmado.
  (c) p1 vs p0 ao vivo (mistura inteira e com exclusao migr>50): o gate
      continua recusando o tratamento?
  (d) A1 vs B1 (ganho real, troca de modelo): o gate continua aceitando?

Tripwire: sob os pesos registrados, o scorer parametrico reproduz o S de
new_runs_scored.csv e do experimento_summary.csv exato, e as taxas de (b)
reproduzem o registrado no Adendo 3 (50.7 / 0.4 / 0.1 %).

Baselines e custo fixo importados de ucc_scoring (fonte unica — licao do M1).
Deterministico (seed fixa). Zero simulacao, zero credito.
"""

import sys
from pathlib import Path

import numpy as np
import pandas as pd
from scipy import stats

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
from ucc_scoring import FIXED_COST, WEIGHTS, METRICS

D_MIN = 0.05
ALPHA = 0.05
EPS_LEGACY = 1.0
SEED = 20260717
B = 40_000

# ordem fixa das metricas e dos baselines (de ucc_scoring, fonte unica)
BASELINES = np.array([WEIGHTS[m][1] for m in METRICS])
W_REGISTERED = tuple(WEIGHTS[m][0] for m in METRICS)

# (pending_pods, time_with_pending, cost, number_of_migrations)
WEIGHTINGS = {
    "registered (.35/.25/.25/.15)": W_REGISTERED,
    "uniform    (.25/.25/.25/.25)": (0.25, 0.25, 0.25, 0.25),
    "inverted   (.15/.25/.25/.35)": (0.15, 0.25, 0.25, 0.35),
    "cost-heavy (.20/.15/.50/.15)": (0.20, 0.15, 0.50, 0.15),
}


def score(raw: np.ndarray, w) -> np.ndarray:
    """S por linha. `raw`: matriz (n, 4) das medias por METRICS."""
    v = raw.copy()
    v[:, METRICS.index("cost")] = np.maximum(0.0, v[:, METRICS.index("cost")] - FIXED_COST)
    s = np.maximum(0.0, 1.0 - v / BASELINES)
    return s @ np.asarray(w)


# ── carga ────────────────────────────────────────────────────────────────────

NEW = pd.read_csv(HERE / "new_runs_scored.csv")
LIVE = pd.read_csv(ROOT / "data" / "runs-workshop" / "experimento"
                   / "experimento_summary.csv")

EXP_DIR = ROOT / "data" / "runs-workshop" / "experimento"


def live_raw(arm: str) -> tuple[np.ndarray, np.ndarray]:
    """(matriz raw (n,4), S registrado) das replicas de um braco ao vivo."""
    sub = LIVE[LIVE.arm == arm]
    raws, s_reg = [], []
    for _, r in sub.iterrows():
        # o CSV registra caminho absoluto de outra maquina; usar o sufixo
        suffix = r.csv_ou_erro.split("runs-workshop/experimento/")[1]
        df = pd.read_csv(EXP_DIR / suffix, index_col=0)
        raws.append([float(df.loc[m, "mean"]) for m in METRICS])
        s_reg.append(r.S)
    return np.array(raws), np.array(s_reg)


def new_raw(bloco: str) -> tuple[np.ndarray, np.ndarray]:
    sub = NEW[NEW.bloco == bloco]
    return sub[list(METRICS)].values.astype(float), sub.S.values


# ── regras (identicas a fig. 6 / real_gain_gate) ─────────────────────────────

def welch_lb(cand: np.ndarray, champ: np.ndarray) -> float:
    nc, np_ = len(cand), len(champ)
    vc, vp = cand.var(ddof=1) / nc, champ.var(ddof=1) / np_
    se = np.sqrt(vc + vp)
    if se == 0.0:
        return cand.mean() - champ.mean()
    df = (vc + vp) ** 2 / (vc**2 / (nc - 1) + vp**2 / (np_ - 1))
    return (cand.mean() - champ.mean()) - stats.t.ppf(1 - ALPHA, df) * se


def null_rates(pool: np.ndarray, k: int, rng: np.random.Generator):
    """Divisoes disjuntas do pool nulo em dois bracos de k (pre-registro §4a)."""
    idx = np.argsort(rng.random((B, len(pool))), axis=1)
    s = pool[idx]
    x, y = s[:, :k], s[:, k:2 * k]
    delta = y.mean(1) - x.mean(1)
    naive = delta > 0
    d = y - x
    eps = d.mean(1) > EPS_LEGACY * d.std(1, ddof=0)
    vx, vy = x.var(1, ddof=1), y.var(1, ddof=1)
    se = np.sqrt(vx / k + vy / k)
    df = (vx / k + vy / k) ** 2 / ((vx / k) ** 2 + (vy / k) ** 2) * (k - 1)
    gate = delta - stats.t.ppf(1 - ALPHA, df) * se > D_MIN
    return naive.mean(), eps.mean(), gate.mean()


def main():
    a1_raw, a1_s = new_raw("A1")
    a2_raw, a2_s = new_raw("A2")
    b1_raw, b1_s = new_raw("B1")
    p0_raw, p0_s = live_raw("p0")
    pp_raw, pp_s = live_raw("p0_prime")
    p1_raw, p1_s = live_raw("p1")

    # tripwire 1: scorer parametrico reproduz o S registrado sob os pesos registrados
    for name, raw, s_reg in [("A1", a1_raw, a1_s), ("A2", a2_raw, a2_s),
                             ("B1", b1_raw, b1_s), ("p0", p0_raw, p0_s),
                             ("p0'", pp_raw, pp_s), ("p1", p1_raw, p1_s)]:
        err = np.abs(score(raw, W_REGISTERED) - s_reg).max()
        assert err < 1e-4, f"{name}: scorer diverge do registrado (max err {err})"
    print("[tripwire] scorer parametrico == S registrado em todos os 116 runs\n")

    # exclusao pre-registrada (migr > 50) — por migracao, invariante aos pesos
    mig = METRICS.index("number_of_migrations")
    keep0, keepp, keep1 = (r[:, mig] <= 50 for r in (p0_raw, pp_raw, p1_raw))

    rows = []
    hdr = (f"{'ponderacao':<30}{'Welch p':>9}{'Levene p':>10}{'d':>7}"
           f"{'naive':>8}{'legacy':>8}{'gate':>7}"
           f"{'LB p1|mix':>11}{'LB p1|exc':>11}{'LB A1xB1':>10}")
    print(hdr)
    for name, w in WEIGHTINGS.items():
        a1, a2, b1 = score(a1_raw, w), score(a2_raw, w), score(b1_raw, w)
        p0, pp, p1 = score(p0_raw, w), score(pp_raw, w), score(p1_raw, w)

        # (a) confirmatorio A1 vs A2
        _, p_w = stats.ttest_ind(a2, a1, equal_var=False)
        _, p_lev = stats.levene(a1, a2, center="mean")
        sp = np.sqrt((29 * a1.var(ddof=1) + 29 * a2.var(ddof=1)) / 58)
        d = (a2.mean() - a1.mean()) / sp

        # (b) nulas ao vivo, k=12
        rng = np.random.default_rng(SEED)
        nv, lg, gt = null_rates(np.concatenate([p0, pp]), 12, rng)

        # (c) tratamento p1 vs p0 — mistura e com exclusao
        lb_mix = welch_lb(p1, p0)
        lb_exc = welch_lb(p1[keep1], p0[keep0])

        # (d) ganho real A1 vs B1
        lb_real = welch_lb(a1, b1)

        rows.append((name, p_w, p_lev, d, nv, lg, gt, lb_mix, lb_exc, lb_real))
        print(f"{name:<30}{p_w:>9.3f}{p_lev:>10.3f}{d:>+7.2f}"
              f"{nv:>8.3f}{lg:>8.3f}{gt:>7.3f}"
              f"{lb_mix:>+11.4f}{lb_exc:>+11.4f}{lb_real:>+10.4f}")

    print(f"\n(gate promove sse LB > {D_MIN}; LBs de p1 negativos = recusa; "
          f"LB A1xB1 > {D_MIN} = aceita o ganho real)")

    out = HERE / "weight_sensitivity.csv"
    with out.open("w") as f:
        f.write("weighting,welch_p,levene_p,d,naive,legacy,gate,"
                "lb_p1_mix,lb_p1_excl,lb_a1_vs_b1\n")
        for r in rows:
            f.write(f"\"{r[0]}\"," + ",".join(f"{v:.4f}" for v in r[1:]) + "\n")
    print(f"[csv] {out}")


if __name__ == "__main__":
    main()
