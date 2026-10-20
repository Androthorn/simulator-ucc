#!/usr/bin/env python3
"""Estatistica do experimento UCC (secao 6 do PLANO-UCC-experimentos).

Compara p0 vs p4 (gemini: A1 vs A2) e a transferencia (haiku: B1 vs B2).
A manchete do paper e COMPRESSAO DE VARIANCIA -> o teste de Levene e a razao
de desvios com IC bootstrap sao o resultado principal, nao a media.

DECISAO (16/07/2026): "p4" = o v5 = p4_VENCEDOR_score0.7392.txt
(sha e46c69aa...). O 0.718 do paper e o v6, prompt DIFERENTE, e nao entra na
comparacao. O baseline e o A1 fresco, intercalado na mesma janela.

Uso:
    ucc_stats.py                # A1 vs A2 e B1 vs B2 (dados novos)
    ucc_stats.py --selftest     # valida a formula e os testes contra dados antigos
    ucc_stats.py --latex        # imprime tambem a tabela LaTeX
"""

import argparse
import json
import re
import sys
from pathlib import Path

import numpy as np
import pandas as pd
from scipy import stats

sys.path.insert(0, str(Path(__file__).parent))
from ucc_scoring import stability_score, METRICS  # fonte unica da formula

DATA = Path(__file__).resolve().parent.parent / "data"   # paper/data, the slim per-run copy
RUNS_DIR = DATA / "runs"
OLD_CSV = DATA / "old_runs" / "outputSummary" / "output" / "combined_summaries.csv"
OLD_RUNS = DATA / "old_runs" / "output"

# sha256 dos prompts canonicos — um run so entra se o provenance bater
SHA_P0 = "dd68a9989439e79fb03b8f2e36024bf05c8ad6a2fe50c23e62bb5024a06ea4bb"
SHA_P4 = "e46c69aa5b34375279fe852b15185b904ab92543b9a4650b2fea8ab4bfe9d7d2"
EXPECTED_SHA = {"A1": SHA_P0, "A2": SHA_P4, "B1": SHA_P0, "B2": SHA_P4}

BOOT = 10_000
RNG = np.random.default_rng(20260716)


# ── carga ────────────────────────────────────────────────────────────────────

def _metrics_from_summary(csv_path: Path) -> dict:
    df = pd.read_csv(csv_path, index_col=0)
    return {m: float(df.loc[m, "mean"]) for m in METRICS if m in df.index}


def load_block(bloco: str) -> list:
    """Runs completos e com prompt verificado. Retorna [(nome, S)]."""
    out, skipped = [], []
    for d in sorted((RUNS_DIR / bloco).glob("*/")):
        prov_f = d / "provenance.json"
        if not prov_f.exists():
            continue
        prov = json.loads(prov_f.read_text())
        if prov.get("status") != "complete":
            skipped.append((d.name, "status != complete"))
            continue
        # o gate de novo, na leitura: nao analisa run cujo prompt divergiu
        sha = (prov.get("prompt") or {}).get("sha256")
        if sha != EXPECTED_SHA[bloco]:
            skipped.append((d.name, f"sha divergente: {sha}"))
            continue
        summ = sorted(d.glob("analyzer/summary/summary_metrics_*.csv"))
        if not summ:
            skipped.append((d.name, "sem summary_metrics"))
            continue
        m = _metrics_from_summary(summ[-1])
        if len(m) != len(METRICS):
            skipped.append((d.name, f"metricas faltando: {set(METRICS)-set(m)}"))
            continue
        out.append((d.name, stability_score(m)))
    for name, why in skipped:
        print(f"    [ignorado] {name}: {why}", file=sys.stderr)
    return out


def load_old(runs) -> list:
    """S dos runs antigos (gemini T=0.1) a partir do combined_summaries.csv."""
    df = pd.read_csv(OLD_CSV)
    df = df[(df.model == "google-gemini-2.5-flash") & (df.threshold == 0.1)]
    out = []
    for r in runs:
        sub = df[df.run_number == r]
        m = dict(zip(sub.metric, sub["mean"]))
        m = {k: v for k, v in m.items() if k in METRICS}
        if len(m) == len(METRICS):
            out.append(stability_score(m))
    return out


def old_batches() -> dict:
    """Lotes antigos rotulados pelo config_used.yaml de cada run."""
    b = {}
    for r in range(1, 65):
        cfg = OLD_RUNS / f"google-gemini-2.5-flash_input_const_v2_0.1_run{r}/config_used.yaml"
        if not cfg.exists():
            continue
        m = re.search(r"consolidator_prompt_file:\s*(\S+)", cfg.read_text(errors="replace"))
        if m:
            b.setdefault(m.group(1), []).append(r)
    return b


# ── testes ───────────────────────────────────────────────────────────────────

def cohens_d(a, b) -> float:
    a, b = np.asarray(a), np.asarray(b)
    na, nb = len(a), len(b)
    sp = np.sqrt(((na - 1) * a.var(ddof=1) + (nb - 1) * b.var(ddof=1)) / (na + nb - 2))
    return (b.mean() - a.mean()) / sp


def boot_ci(a, b, stat, alpha=0.05):
    a, b = np.asarray(a), np.asarray(b)
    vals = np.empty(BOOT)
    for i in range(BOOT):
        ra = RNG.choice(a, len(a), replace=True)
        rb = RNG.choice(b, len(b), replace=True)
        vals[i] = stat(ra, rb)
    return np.percentile(vals, [100 * alpha / 2, 100 * (1 - alpha / 2)])


def compare(a, b, label_a, label_b, title):
    a, b = np.asarray(a), np.asarray(b)
    print(f"\n{'='*74}\n{title}\n{'='*74}")
    print(f"  {label_a:<28} n={len(a):>2}  mean={a.mean():.4f}  std={a.std(ddof=1):.4f}")
    print(f"  {label_b:<28} n={len(b):>2}  mean={b.mean():.4f}  std={b.std(ddof=1):.4f}")
    if len(a) < 3 or len(b) < 3:
        print("  (n insuficiente para testes)")
        return None

    # --- media ---
    t, p_t = stats.ttest_ind(a, b, equal_var=False)
    u, p_u = stats.mannwhitneyu(a, b, alternative="two-sided")
    d = cohens_d(a, b)
    ci_d = boot_ci(a, b, lambda x, y: y.mean() - x.mean())
    print("\n  -- tendencia central --")
    print(f"     Welch t-test      t={t:+.3f}   p={p_t:.4f}")
    print(f"     Mann-Whitney U    U={u:.1f}    p={p_u:.4f}")
    print(f"     Cohen's d         {d:+.3f}")
    print(f"     IC95% da dif.     [{ci_d[0]:+.4f}, {ci_d[1]:+.4f}]  (bootstrap {BOOT})")

    # --- variancia (A MANCHETE) ---
    W, p_lev = stats.levene(a, b, center="mean")
    Wbf, p_bf = stats.levene(a, b, center="median")  # Brown-Forsythe
    sa, sb = a.std(ddof=1), b.std(ddof=1)
    ratio = sa / sb
    F = a.var(ddof=1) / b.var(ddof=1)
    ci_r = boot_ci(a, b, lambda x, y: x.std(ddof=1) / y.std(ddof=1))
    print("\n  -- variancia (manchete do paper) --")
    print(f"     Levene (mean)     W={W:.3f}   p={p_lev:.4f}")
    print(f"     Brown-Forsythe    W={Wbf:.3f}   p={p_bf:.4f}")
    print(f"     F = s_a^2/s_b^2   {F:.3f}")
    print(f"     razao s_a/s_b     {ratio:.3f}   IC95% [{ci_r[0]:.3f}, {ci_r[1]:.3f}]")
    veredito = "COMPRIME" if (p_lev < 0.05 and ratio > 1) else "nao-significativo"
    print(f"     -> variancia: {veredito}")
    return dict(n_a=len(a), n_b=len(b), mean_a=a.mean(), mean_b=b.mean(),
                std_a=sa, std_b=sb, p_welch=p_t, p_mw=p_u, d=d,
                p_levene=p_lev, ratio=ratio, F=F)


def latex_table(rows):
    print("\n% --- tabela LaTeX ---")
    print(r"\begin{tabular}{lrrrrrr}")
    print(r"\toprule")
    print(r"Group & $n$ & Mean & Std & Welch $p$ & Levene $p$ & $\sigma$ ratio \\")
    print(r"\midrule")
    for lbl, r in rows:
        if r is None:
            continue
        print(f"{lbl} & {r['n_a']} & {r['mean_a']:.3f} & {r['std_a']:.3f} & "
              f"\\multirow{{2}}{{*}}{{{r['p_welch']:.3f}}} & "
              f"\\multirow{{2}}{{*}}{{{r['p_levene']:.3f}}} & "
              f"\\multirow{{2}}{{*}}{{{r['ratio']:.2f}}} \\\\")
    print(r"\bottomrule")
    print(r"\end{tabular}")


# ── selftest ─────────────────────────────────────────────────────────────────

def selftest():
    print("SELFTEST — formula e pipeline contra os dados antigos (ground truth §3.4)")
    print("="*74)
    casos = [("gemini p0 (1-10)", range(1, 11), 0.695, 0.075),
             ("gemini p4=v6 (55-64)", range(55, 65), 0.718, 0.044)]
    ok = True
    for nome, rr, em, es in casos:
        s = load_old(rr)
        mu, sd = np.mean(s), np.std(s, ddof=1)
        good = abs(mu - em) < 0.001 and abs(sd - es) < 0.001
        ok &= good
        print(f"  {nome:<24} mean={mu:.3f} (esp {em})  std={sd:.3f} (esp {es})  "
              f"{'OK' if good else '<<< DIVERGE'}")
    print(f"\n  {'PORT VALIDADO' if ok else 'PORT DIVERGENTE'}\n")

    print("Lotes antigos rotulados (config_used.yaml):")
    b = old_batches()
    for lbl, runs in b.items():
        s = load_old(runs)
        print(f"  {lbl:<26} n={len(s):>2}  mean={np.mean(s):.3f}  std={np.std(s, ddof=1):.3f}")

    # o piloto, sob a decisao nova: v1 vs v5
    v1 = load_old(b.get("consolidator_agent", []))
    v5_all = load_old(b.get("consolidator_agent_v5", []))
    v5_paper = load_old(range(38, 48))
    compare(v1, v5_paper, "v1 (p0, runs 1-10)", "v5 (p4, runs 38-47)",
            "PILOTO n=10 — p0 vs p4(v5), como o paper reporta")
    compare(v1, v5_all, "v1 (p0, runs 1-10)", "v5 (p4, runs 34-47)",
            "PILOTO — o mesmo, mas incluindo os 4 runs descartados (34-37)")


# ── main ─────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--latex", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        selftest()
        return

    rows = []
    a1, a2 = load_block("A1"), load_block("A2")
    r = compare([s for _, s in a1], [s for _, s in a2], "A1 gemini p0", "A2 gemini p4 (v5)",
                "GEMINI — claim central (p0 vs p4)")
    rows += [("gemini p0", r), ("gemini p4", r)]

    b1, b2 = load_block("B1"), load_block("B2")
    if b1 and b2:
        r = compare([s for _, s in b1], [s for _, s in b2], "B1 haiku p0", "B2 haiku p4 (v5)",
                    "HAIKU — transferencia (exploratorio, n=10)")
        rows += [("haiku p0", r), ("haiku p4", r)]
    else:
        print(f"\n(bloco haiku incompleto: B1={len(b1)}, B2={len(b2)} — pulado)")

    if args.latex:
        latex_table(rows)


if __name__ == "__main__":
    main()
