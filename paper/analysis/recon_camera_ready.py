#!/usr/bin/env python3
"""Recalculos para o camera-ready UCC 2026 (19/10/2026). So leitura dos dados congelados.

W2 poder · W3 sensibilidade a delta_min e shift injetado · W5 tabela V com o gate · Q5 taxa exata.
Gate: promove sse LB unilateral 95% (Welch) de mean(cand)-mean(champ) > delta_min.
"""
from itertools import combinations
import numpy as np, pandas as pd
from scipy import stats

from pathlib import Path
A = str(Path(__file__).resolve().parent) + '/'
old = pd.read_csv(A + 'old_gemini_labeled.csv')
new = pd.read_csv(A + 'new_runs_scored.csv')
ex = pd.read_csv(Path(__file__).resolve().parent.parent / 'data' / 'runs-workshop' / 'experimento' / 'experimento_summary.csv')
SEED, B = 20261019, 40_000
g = {b: new[new.bloco == b].S.values for b in ['A1', 'A2', 'B1', 'B2']}
arm = lambda a, excl=False: ex[(ex.arm == a) & ((ex.migrations <= 50) | (not excl))].S.values


def lb(c, p, alpha=.05):
    """LB unilateral; vetorizado na ultima dimensao."""
    nc, np_ = c.shape[-1], p.shape[-1]
    vc, vp = c.var(-1, ddof=1) / nc, p.var(-1, ddof=1) / np_
    se = np.sqrt(vc + vp)
    df = (vc + vp) ** 2 / (vc ** 2 / (nc - 1) + vp ** 2 / (np_ - 1))
    return c.mean(-1) - p.mean(-1) - stats.t.ppf(1 - alpha, df) * se


def power2(d, s1, s2, n, alpha=.05):
    se, df = np.sqrt(s1**2 / n + s2**2 / n), 2 * n - 2
    tc = stats.t.ppf(1 - alpha / 2, df)
    return 1 - stats.nct.cdf(tc, df, d / se) + stats.nct.cdf(-tc, df, d / se)


def shift_rates(pool, k, shifts, margins, rng):
    idx = np.argsort(rng.random((B, len(pool))), axis=1)
    s = pool[idx]; c0, p = s[:, :k], s[:, k:2 * k]
    return {sh: [float((lb(c0 + sh, p) > m).mean()) for m in margins] for sh in shifts}


rng = np.random.default_rng(SEED)
print('== W5 piloto (CFIXED)')
v1 = old[old.prompt_file == 'consolidator_agent'].S.values
v5p = old[old.run.between(38, 47)].S.values
print(f' v1 {v1.mean():.4f}±{v1.std(ddof=1):.4f}  v5(38-47) {v5p.mean():.4f}±{v5p.std(ddof=1):.4f}'
      f'  ganho {v5p.mean()/v1.mean()-1:+.1%}  sd {v5p.std(ddof=1)/v1.std(ddof=1)-1:+.1%}')
print('== W5c tabela V com o gate (vs v1, v5 com 14 runs)')
for f in ['_v2', '_v3', '_v4', '_v5', '_v6']:
    c = old[old.prompt_file == 'consolidator_agent' + f].S.values
    print(f' v{f[-1]} n={len(c)} diff={c.mean()-v1.mean():+.4f} LB={lb(c, v1):+.4f}')
print(f' v5 38-47 diff={v5p.mean()-v1.mean():+.4f} LB={lb(v5p, v1):+.4f}')

print('== W2 poder para +0.044, n=30, Welch bilateral')
print(f' SDs piloto {power2(.044,.074,.035,30):.3f}  SDs observados {power2(.044,.108,.103,30):.3f}'
      f'  n p/80% {next(n for n in range(5,400) if power2(.044,.108,.103,n)>=.8)}')

print('== W3 LB de cada comparacao')
for k, (c, p) in {'A2 vs A1': (g['A2'], g['A1']), 'p1 vs p0 mix': (arm('p1'), arm('p0')),
                  'p1 vs p0 excl': (arm('p1', 1), arm('p0', 1)), "p0' vs p0 mix": (arm('p0_prime'), arm('p0')),
                  "p0' vs p0 excl": (arm('p0_prime', 1), arm('p0', 1)), 'A1 vs B1': (g['A1'], g['B1'])}.items():
    print(f' {k:15s} diff={c.mean()-p.mean():+.4f} LB={lb(c, p):+.4f}')

print('== Q5/W3 taxa EXATA sob a nula, 24 replicas ao vivo, k=12, todas as 2.704.156 divisoes ordenadas')
null = np.concatenate([arm('p0'), arm('p0_prime')])
ci = np.array(list(combinations(range(24), 12)), dtype=np.int8)
mask = np.ones((len(ci), 24), bool); mask[np.arange(len(ci))[:, None], ci] = False
cand, champ = null[ci], null[np.where(mask)[1].reshape(len(ci), 12)]
L, naive = lb(cand, champ), cand.mean(1) > champ.mean(1)
print(f' naive {naive.mean():.4%}  (legacy eps-sigma pareia por zip, precisa de MC, fica fora)')
for m in [0, .02, .03, .05]:
    print(f' gate delta_min={m}: {(L > m).mean():.5%}  ({int((L > m).sum())} de {len(L)})')

M = [0, .02, .05]
print(f'== W3 shift injetado, ao vivo comprimido, k=12, B={B}, margens {M}')
for sh, r in shift_rates(null, 12, [.02, .044, .05, .073, .10, .12], M, rng).items():
    print(f' {sh:.3f}: ' + '  '.join(f'{x:.3f}' for x in r))
print(f'== W3 shift injetado, A1 (30 min, mesmo cenario do p4), 15 vs 15, B={B}, margens {M}')
for sh, r in shift_rates(g['A1'], 15, [0, .02, .044, .05, .073, .10, .12], M, rng).items():
    print(f' {sh:.3f}: ' + '  '.join(f'{x:.3f}' for x in r))


# ---- Q5: legacy por MC e IC bootstrap sobre as 24 replicas (pre-registro §4a) ----
def rule_rates(pool, k, B_split, rng, margin=.05, eps=1.0):
    idx = np.argsort(rng.random((B_split, len(pool))), axis=1)
    s = pool[idx]; c, p = s[:, :k], s[:, k:2 * k]
    naive = (c.mean(1) > p.mean(1)).mean()
    d = c - p
    legacy = (d.mean(1) > eps * d.std(1, ddof=0)).mean()
    gate = (lb(c, p) > margin).mean()
    return naive, legacy, gate

rng2 = np.random.default_rng(SEED + 1)
pt = rule_rates(null, 12, 400_000, rng2)
print(f'== Q5 ponto (MC 400k divisoes): naive {pt[0]:.4%}  legacy {pt[1]:.4%}  gate {pt[2]:.4%}')
boot = np.array([rule_rates(rng2.choice(null, 24, replace=True), 12, 20_000, rng2) for _ in range(2000)])
lo, hi = np.percentile(boot, [2.5, 97.5], axis=0)
for i, r in enumerate(['naive', 'legacy', 'gate']):
    print(f' {r:6s} IC95 bootstrap sobre replicas [{lo[i]:.2%}, {hi[i]:.2%}]')


# ---- 20/10: runs 34-37 rodaram o v5 de 2 exemplos (marcador 'churn' ausente) ----
print('== p4 historico so com os 10 runs do prompt de 3 exemplos (38-47)')
w = lambda a, b: stats.ttest_ind(a, b, equal_var=False).pvalue
lev = lambda a, b: stats.levene(a, b, center='mean').pvalue
def cd(a, b):
    sp = np.sqrt(((len(a)-1)*a.var(ddof=1)+(len(b)-1)*b.var(ddof=1))/(len(a)+len(b)-2)); return (a.mean()-b.mean())/sp
v5_2ex = old[old.run.between(34, 37)].S.values
print(f' v5 2 exemplos (34-37): n=4 {v5_2ex.mean():.4f}±{v5_2ex.std(ddof=1):.4f}')
print(f' v5(38-47) vs v1 historico: diff={v5p.mean()-v1.mean():+.4f} Welch p={w(v5p,v1):.3f} Levene p={lev(v5p,v1):.4f} d={cd(v5p,v1):+.2f} sd ratio v1/v5={v1.std(ddof=1)/v5p.std(ddof=1):.2f} LB={lb(v5p,v1):+.4f}')
print(f' v5(38-47) vs A2 fresco: diff={v5p.mean()-g["A2"].mean():+.4f} Welch p={w(v5p,g["A2"]):.3f} Levene p={lev(v5p,g["A2"]):.4f} d={cd(v5p,g["A2"]):+.2f}')
print(f' v1 historico vs A1 fresco: Welch p={w(v1,g["A1"]):.3f} d={cd(v1,g["A1"]):+.2f}')
