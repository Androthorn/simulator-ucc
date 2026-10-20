#!/usr/bin/env python3
"""O gate corrigido aceitando uma melhoria REAL: A1 (gemini) vs B1 (haiku).

Responde a objecao "um gate que rejeita tudo e trivialmente seguro; voces
provaram que e conservador, nao que e poderoso". Os dados congelados do TCC
ja contem uma melhoria real de qualidade conhecida — a troca de modelo
(d~1.6, o achado-ancora do paper). Runs reais, zero simulacao, zero credito.

Duas leituras:
  1. Gate no braco inteiro (n=30 vs n=10): promove gemini sobre haiku?
  2. Taxa de promocao VERDADEIRA x k (subamostras sem reposicao dentro de
     cada braco), pras mesmas tres regras da fig. 6. E o complemento da
     figura-assinatura: la, a taxa sob a nula (deve ser ~alpha); aqui, sob
     um ganho real (deve subir a ~1). Mesmos parametros do pre-registro:
     delta_min=0.05, alpha=0.05 unilateral, eps=1.0.

Declarado: e escolha de modelo, nao um candidato de prompt, e no regime de
30 min — a alegacao em teste e o poder do gate sobre distribuicoes de score
reais, nao sobre prompts.

Fonte unica de score: new_runs_scored.csv (tripwire: re-score via ucc_scoring
bate exato). Deterministico (seed fixa). Roda em segundos.
"""

import sys
from pathlib import Path

import numpy as np
import pandas as pd
from scipy import stats

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from ucc_scoring import stability_score, METRICS

D_MIN = 0.05       # margem do gate (pre-registro §4b)
ALPHA = 0.05       # unilateral (pre-registro §4b)
EPS_LEGACY = 1.0   # epsilon da regra antiga
SEED = 20260717
B = 40_000
KS = [2, 3, 5, 8, 10]   # k <= 10 (B1 tem 10 replicas; sem reposicao)

NEW = pd.read_csv(HERE / "new_runs_scored.csv")


def load_block(bloco: str) -> np.ndarray:
    sub = NEW[NEW.bloco == bloco]
    # tripwire: o S do CSV tem que ser reproduzido pela fonte unica da formula
    for _, r in sub.iterrows():
        s = stability_score({m: r[m] for m in METRICS})
        assert abs(s - r.S) < 1e-5, f"{bloco}/{r.run}: re-score {s} != csv {r.S}"
    return sub.S.values


def welch_lb(cand: np.ndarray, champ: np.ndarray) -> float:
    """Limite inferior do IC unilateral (1-alpha) de mean(cand) - mean(champ)."""
    nc, np_ = len(cand), len(champ)
    vc, vp = cand.var(ddof=1) / nc, champ.var(ddof=1) / np_
    se = np.sqrt(vc + vp)
    df = (vc + vp) ** 2 / (vc**2 / (nc - 1) + vp**2 / (np_ - 1))
    return (cand.mean() - champ.mean()) - stats.t.ppf(1 - ALPHA, df) * se


def cohens_d(a, b) -> float:
    na, nb = len(a), len(b)
    sp = np.sqrt(((na - 1) * a.var(ddof=1) + (nb - 1) * b.var(ddof=1)) / (na + nb - 2))
    return (b.mean() - a.mean()) / sp


def true_promotion_rates(cand: np.ndarray, champ: np.ndarray, k: int,
                         rng: np.random.Generator) -> tuple[float, float, float]:
    """Fracao de subamostras (k de cada braco, sem reposicao) que cada regra promove."""
    ic = np.argsort(rng.random((B, len(cand))), axis=1)[:, :k]
    ip = np.argsort(rng.random((B, len(champ))), axis=1)[:, :k]
    y, x = cand[ic], champ[ip]           # y = candidato (gemini), x = campeao (haiku)
    delta = y.mean(1) - x.mean(1)

    naive = delta > 0
    d = y - x                            # legacy: pareada por zip (ordem ja e aleatoria)
    eps = d.mean(1) > EPS_LEGACY * d.std(1, ddof=0)
    vy, vx = y.var(1, ddof=1), x.var(1, ddof=1)
    se = np.sqrt(vy / k + vx / k)
    df = (vy / k + vx / k) ** 2 / ((vy / k) ** 2 + (vx / k) ** 2) * (k - 1)
    gate = delta - stats.t.ppf(1 - ALPHA, df) * se > D_MIN
    return naive.mean(), eps.mean(), gate.mean()


def main():
    a1 = load_block("A1")   # gemini p0, n=30 — candidato
    b1 = load_block("B1")   # haiku  p0, n=10 — campeao
    print(f"A1 (gemini p0)  n={len(a1)}  mean={a1.mean():.4f}  std={a1.std(ddof=1):.4f}")
    print(f"B1 (haiku  p0)  n={len(b1)}  mean={b1.mean():.4f}  std={b1.std(ddof=1):.4f}")

    diff = a1.mean() - b1.mean()
    lb = welch_lb(a1, b1)
    print("\n1. GATE NO BRACO INTEIRO (candidato=gemini, campeao=haiku)")
    print(f"   diff={diff:+.4f}   d={cohens_d(b1, a1):+.2f}   LB={lb:+.4f}   "
          f"delta_min={D_MIN}  ->  {'PROMOVE' if lb > D_MIN else 'rejeita'}")

    print(f"\n2. TAXA DE PROMOCAO VERDADEIRA x k  (B={B}, sem reposicao, seed={SEED})")
    print(f"{'k':>4}{'naive':>10}{'legacy':>10}{'gate':>10}")
    rng = np.random.default_rng(SEED)
    rows = []
    for k in KS:
        nv, lg, gt = true_promotion_rates(a1, b1, k, rng)
        rows.append((k, nv, lg, gt))
        print(f"{k:>4}{nv:>10.3f}{lg:>10.3f}{gt:>10.3f}")

    out = HERE / "real_gain_promotion_by_k.csv"
    with out.open("w") as f:
        f.write("k,naive,legacy,gate\n")
        for k, nv, lg, gt in rows:
            f.write(f"{k},{nv:.4f},{lg:.4f},{gt:.4f}\n")
    print(f"\n[csv] {out}")


if __name__ == "__main__":
    main()
