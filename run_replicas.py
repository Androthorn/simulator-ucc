#!/usr/bin/env python3
"""Runner de k réplicas — validação de gate 1 (variância + headroom). SEM refino.

Roda k réplicas do MESMO prompt (p0 por padrão) no cenário comprimido, pontua cada
uma com o S auditado, e reporta a distribuição vs. o baseline de 30 min. É a
ferramenta do passo 1 do brief: ver se a variância não explode e se há headroom.

- Idempotente: réplica com provenance 'complete' + CSV é pulada (retomável).
- Sem exclusão silenciosa: réplica que falha é REGISTRADA (S vazio) e o loop segue.
- DRY por padrão: imprime plano + custo estimado e sai. Precisa de --go pra rodar.

Rodar:
  <python do venv com o hefesto> run_replicas.py        # plano (dry)
  <python do venv com o hefesto> run_replicas.py --go    # roda de verdade
  ... --go -k 10                                                              # k réplicas
"""
import argparse
import csv as csvmod
import hashlib
import json
import statistics as st
import sys
from pathlib import Path

import yaml

from smoke_1_replica import SIM, CONFIG, RUNS, P0, preflight

# Baseline de 30 min (bloco A1, p0, gemini-2.5-flash) — pra comparação de gate 1.
BASELINE_30MIN = {"mean": 0.671, "std": 0.108, "n": 30}
COST_PER_SIM_USD = 0.26          # analysis/CUSTO-experimento.md (gemini-2.5-flash)


def dispatch_modes(k: int) -> list[str]:
    """Réplica 1 semeia o cluster (full); 2..k reusam (light). Um entry-point."""
    return ["full" if i == 1 else "light" for i in range(1, k + 1)]


def _existing_csv(dest: Path):
    hits = sorted((dest / "analyzer" / "summary").glob("summary_metrics_*.csv"))
    return hits[-1] if hits else None


def _current_input_sha() -> str:
    """sha do input que o config aponta hoje — pra saber se uma réplica velha é reutilizável."""
    cfg = yaml.safe_load(CONFIG.read_text())
    name = cfg["ai-engine"]["data"]["input_json"]
    return hashlib.sha256((SIM / "simulator" / "data" / name).read_bytes()).hexdigest()


def _is_complete(dest: Path) -> bool:
    """Completa E válida: provenance 'complete', CSV presente, e o input bate com o atual
    (senão é de outro cenário — ex.: smoke a 600s vs batch a 700s — e deve re-rodar)."""
    prov = dest / "provenance.json"
    if not prov.exists() or _existing_csv(dest) is None:
        return False
    try:
        p = json.loads(prov.read_text())
        return (p.get("status") == "complete"
                and p.get("input", {}).get("sha256") == _current_input_sha())
    except Exception:
        return False


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-k", type=int, default=10, help="número de réplicas (default 10)")
    ap.add_argument("--go", action="store_true", help="roda de verdade (senão só o plano)")
    ap.add_argument("--batch", default="p0_batch",
                    help="subdir em runs-workshop/ (default p0_batch; use outro p/ certificação light)")
    args = ap.parse_args()

    batch_dir = RUNS / args.batch
    summary_csv = batch_dir / "p0_replicas_summary.csv"
    modes = dispatch_modes(args.k)

    prompt = P0.read_text(encoding="utf-8")  # candidato = p0 (baseline). Sem refino.
    dests = [(batch_dir / f"r_{hashlib.sha256(prompt.encode()).hexdigest()[:8]}_{i}", i)
             for i in range(1, args.k + 1)]
    todo = [d for d in dests if not _is_complete(d[0])]
    done = len(dests) - len(todo)

    print(f"Plano: {args.k} réplicas de p0 no cenário comprimido (réplica 1 full, 2..k light).")
    print(f"  já completas (serão puladas): {done}   a rodar: {len(todo)}")
    print(f"  custo estimado: ~${len(todo) * COST_PER_SIM_USD:.2f} (OpenRouter, gemini-2.5-flash)")
    todo_modes = [modes[i - 1] for (_, i) in todo]
    wall = sum(15 if m == "full" else 12 for m in todo_modes)
    print(f"  parede estimada: ~{wall} min (~{wall / 60:.1f} h)   [full≈15, light≈12]")
    print(f"  destino: {batch_dir}/r_<sha8>_<i>   resumo: {summary_csv}")

    if args.batch == "p0_batch" and any(modes[i - 1] == "light" for (_, i) in todo):
        print("❌ recusando: --batch p0_batch é o baseline FULL congelado (10 réplicas). "
              "Rodar réplicas light aqui contaminaria o conjunto de comparação da certificação. "
              "Use --batch p0_light_cert (ou outro nome).", file=sys.stderr)
        return 2

    if not args.go:
        print("\n(DRY) nada foi rodado. Re-execute com --go pra disparar. Gate 1: avise os "
              "orientadores e confirme o custo antes.")
        return 0

    problems = preflight()
    if problems:
        print("\n❌ pré-checagem falhou:")
        for p in problems:
            print("   -", p)
        return 1

    from hefesto.runner.wasp_runner import WASPRunner, RunnerError
    from hefesto.grader.stability_grader import StabilityGrader
    from hefesto.schemas.core import TestCase, Objective

    batch_dir.mkdir(parents=True, exist_ok=True)
    runner = WASPRunner(SIM, CONFIG, batch_dir, reset_mode="full")
    grader = StabilityGrader()
    obj = Objective(goal="stability")

    rows = []  # (i, S|None, csv_path|erro)
    for dest, i in dests:
        if _is_complete(dest):
            csv = _existing_csv(dest)
            from hefesto.schemas.core import Output
            out = Output(text=str(csv), metadata={"csv": str(csv)})
            S = grader.grade(TestCase(input=""), out, obj).scores["stability"]
            print(f"[{i:02d}/{args.k}] pulada (já completa) S={S:.4f}")
            rows.append((i, S, str(csv)))
            continue
        mode = modes[i - 1]
        print(f"[{i:02d}/{args.k}] rodando réplica real ({mode}, ~{15 if mode=='full' else 12}min)...", flush=True)
        try:
            out = runner.run(prompt, TestCase(input="", metadata={"replica": i, "reset_mode": mode}))
        except RunnerError as e:
            print(f"[{i:02d}/{args.k}] ❌ FALHOU: {e}  (registrada, seguindo)")
            rows.append((i, None, f"ERRO: {e}"))
            continue
        S = grader.grade(TestCase(input=""), out, obj).scores["stability"]
        print(f"[{i:02d}/{args.k}] ✓ S={S:.4f}")
        rows.append((i, S, out.metadata["csv"]))

    # --- resumo ---
    with open(summary_csv, "w", newline="") as f:
        w = csvmod.writer(f)
        w.writerow(["replica", "S", "csv_ou_erro"])
        for i, S, ref in rows:
            w.writerow([i, "" if S is None else f"{S:.6f}", ref])

    scores = [S for _, S, _ in rows if S is not None]
    fails = [i for i, S, _ in rows if S is None]
    print("\n" + "─" * 48)
    print(f"RESUMO — {len(scores)}/{args.k} réplicas com S (falhas: {fails or 'nenhuma'})")
    if scores:
        mean, std = st.mean(scores), (st.pstdev(scores) if len(scores) > 1 else 0.0)
        print(f"  comprimido: mean={mean:.4f}  std={std:.4f}  "
              f"min={min(scores):.4f}  med={st.median(scores):.4f}  max={max(scores):.4f}")

        import json as _json
        def _mode_of(dest: Path) -> str:
            prov = dest / "provenance.json"
            try:
                return _json.loads(prov.read_text()).get("reset_mode", "?")
            except Exception:
                return "?"

        by_mode = {"full": [], "light": []}
        for (dest, i), (ri, S, _) in zip(dests, rows):
            if S is not None:
                by_mode.setdefault(_mode_of(dest), []).append(S)
        for m in ("full", "light"):
            g = by_mode.get(m, [])
            if g:
                mmean, mstd = st.mean(g), (st.pstdev(g) if len(g) > 1 else 0.0)
                print(f"  {m:5s}: n={len(g)} mean={mmean:.4f} std={mstd:.4f} "
                      f"min={min(g):.4f} med={st.median(g):.4f} max={max(g):.4f}")
        for m, g in by_mode.items():
            if m in ("full", "light") or not g:
                continue
            mmean, mstd = st.mean(g), (st.pstdev(g) if len(g) > 1 else 0.0)
            print(f"  {m:5s}: n={len(g)} mean={mmean:.4f} std={mstd:.4f} "
                  f"min={min(g):.4f} med={st.median(g):.4f} max={max(g):.4f}")

        b = BASELINE_30MIN
        print(f"  30min (A1): mean={b['mean']:.3f}  std={b['std']:.3f}  (n={b['n']})")
        plateau = sum(1 for s in scores if s >= 0.72)
        tail = sum(1 for s in scores if s <= 0.45)
        print(f"  headroom: {plateau}/{len(scores)} no platô (S≥0.72), {tail} na cauda (S≤0.45)")
        if std > 1.5 * b["std"]:
            print("  ⚠️ variância ~50%+ acima do 30min — reportar ao gate 1.")
        if mean >= b["mean"] + 0.04 and plateau >= 0.7 * len(scores):
            print("  ⚠️ p0 pontua alto/satura — possível FALTA de headroom. Considerar endurecer "
                  "o workload (mais deploys / menos nós), nunca afrouxar o S. Gate 1.")
    print(f"  resumo salvo em {summary_csv}")
    print("─" * 48)
    return 0


if __name__ == "__main__":
    sys.exit(main())
