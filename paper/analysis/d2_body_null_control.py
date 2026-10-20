#!/usr/bin/env python3
"""Controle nulo retrospectivo do corpo da distribuicao (D2, secao V-C do paper).

Pergunta: a compressao aparente no corpo (MAD 4x menor, mediana +0.042 de p0 para
p4 nos blocos confirmatorios A1/A2) e um efeito real que o Levene sobre sigma nao
pegou, ou esta dentro do ruido do proprio baseline?

Metodo: constroi a distribuicao nula de dMAD e dMediana com o baseline contra si
mesmo (bootstrap de A1 em dois bracos de n=30) e por permutacao do pool A1+A2.
Compara com a diferenca observada p0-p4. Tamanho casado com o observado (30 vs 30);
o split 15/15 infla a nula e nao deve ser usado.

Fonte da formula: ucc_scoring.stability_score. Runs: simulatormeu/runs/{A1,A2}.
Reproduz: python analysis/d2_body_null_control.py
"""
import glob, numpy as np, pandas as pd
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).parent))
from ucc_scoring import stability_score, METRICS

RUNS = Path(__file__).resolve().parent.parent / "data" / "runs"
SEED = 20260716
N = 100_000

def load(block):
    out = []
    for f in sorted(glob.glob(str(RUNS / block / "*/analyzer/summary/summary_metrics_*.csv"))):
        df = pd.read_csv(f, index_col=0)
        out.append(stability_score({k: float(df.loc[k, "mean"]) for k in METRICS}))
    return np.array(out)

def madv(X):  # MAD por linha (scale=1)
    med = np.median(X, axis=1, keepdims=True)
    return np.median(np.abs(X - med), axis=1)

def one_sided(obs, null):
    return float(np.mean(null <= obs) if obs < 0 else np.mean(null >= obs))

def main():
    a1, a2 = load("A1"), load("A2")
    assert len(a1) == 30 and len(a2) == 30, (len(a1), len(a2))
    mad1, mad2 = float(madv(a1[None])[0]), float(madv(a2[None])[0])
    dMAD = mad2 - mad1
    dMed = float(np.median(a2) - np.median(a1))
    print(f"A1(p0): mean={a1.mean():.4f} std={a1.std(ddof=1):.4f} median={np.median(a1):.4f} MAD={mad1:.4f}")
    print(f"A2(p4): mean={a2.mean():.4f} std={a2.std(ddof=1):.4f} median={np.median(a2):.4f} MAD={mad2:.4f}")
    print(f"observado p4-p0: dMAD={dMAD:+.4f}  dMediana={dMed:+.4f}\n")

    rng = np.random.default_rng(SEED)
    # within-baseline bootstrap 30v30 (primario, analogo do braco p0')
    A = a1[rng.integers(0, 30, (N, 30))]; B = a1[rng.integers(0, 30, (N, 30))]
    print("within-baseline bootstrap (A1 contra si, 30v30):")
    print(f"  dMAD    1-sided p={one_sided(dMAD, madv(B)-madv(A)):.4f}")
    print(f"  dMediana 1-sided p={one_sided(dMed, np.median(B,axis=1)-np.median(A,axis=1)):.4f}")
    # permutacao pool A1+A2 (corroboracao, H0: p0==p4)
    pool = np.concatenate([a1, a2]); pm = np.argsort(rng.random((N, 60)), axis=1)
    G1, G2 = pool[pm[:, :30]], pool[pm[:, 30:]]
    print("permutacao pool(A1,A2) relabel 30/30:")
    print(f"  dMAD    1-sided p={one_sided(dMAD, madv(G2)-madv(G1)):.4f}")
    print(f"  dMediana 1-sided p={one_sided(dMed, np.median(G2,axis=1)-np.median(G1,axis=1)):.4f}")

if __name__ == "__main__":
    main()
