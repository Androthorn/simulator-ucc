#!/usr/bin/env python3
"""Runner dos tres bracos do ciclo controlado — executa PRE-REGISTRO-workshop.md.

Nao substitui o run_replicas.py: aquele e a ferramenta do gate 1 (k replicas de UM
prompt, comparacao com o baseline de 30 min, aviso de headroom) e produziu o
baseline e o smoke. Este roda o experimento pre-registrado, que tem semantica
diferente: tres bracos intercalados, sem julgamento de headroom.

O desenho, do pre-registro:
  p0        campeao
  p0_prime  o MESMO p0 de novo  -> controle nulo
  p1        p0 + 2 few-shots    -> tratamento

Duas propriedades que o `hefesto.core.schedule` garante e que errar destruiria o
experimento em silencio:
  - intercalacao (p0, p0', p1, p0, ...), para deriva temporal do cluster atingir
    os tres igualmente em vez de virar diferenca entre eles;
  - reset balanceado: o modo depende do indice DENTRO do braco, entao cada braco
    recebe 1 full + (k-1) light. Com o modo global antigo so o primeiro run do
    conjunto seria full e um braco teria mistura diferente dos outros -- confound
    enquanto a certificacao `light == full` nao existir.

p0 e p0' sao o mesmo prompt e portanto o mesmo sha8: o braco entra no CAMINHO do
diretorio de destino, nunca so o hash.

Rodar (a partir de qualquer lugar):
  hefesto/.venv/bin/python simulatormeu/run_experiment.py             # plano (dry)
  hefesto/.venv/bin/python simulatormeu/run_experiment.py --go        # roda de verdade
"""
import argparse
import csv as csvmod
import hashlib
import statistics as st
import sys
from pathlib import Path

from hefesto.core.schedule import arm_run_dir, arm_schedule
from run_replicas import COST_PER_SIM_USD, _existing_csv, _is_complete
from smoke_1_replica import CONFIG, P0, RUNS, SIM, preflight

P1 = SIM / "ai-engine" / "prompts" / "workshop" / "consolidator_agent_p1.txt"

# Ordem e nomes fixados pelo pre-registro. p0_prime le o MESMO arquivo que p0.
ARMS = {"p0": P0, "p0_prime": P0, "p1": P1}

# Criterios de exclusao pre-registrados (PRE-REGISTRO-workshop.md §3).
THRASH_MIGR = 50   # migr > 50  -> thrash, fora da confirmatoria
STALL_MIGR = 0     # migr == 0  -> stall, tripwire: exclui E reporta


def _migrations(csv_path) -> float | None:
    """Contagem media de migracoes — o eixo dos criterios de exclusao."""
    if csv_path is None:
        return None
    try:
        with open(csv_path) as f:
            for row in csvmod.DictReader(f):
                if row[""] == "number_of_migrations":
                    return float(row["mean"])
    except Exception:
        return None
    return None


def _classify(migr: float | None) -> str:
    if migr is None:
        return "?"
    if migr == STALL_MIGR:
        return "STALL"
    if migr > THRASH_MIGR:
        return "thrash"
    return "normal"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-k", type=int, default=12, help="replicas por braco (default 12, pre-registrado)")
    ap.add_argument("--go", action="store_true", help="roda de verdade (senao so o plano)")
    ap.add_argument("--batch", default="experimento", help="subdir em runs-workshop/")
    args = ap.parse_args()

    batch_dir = RUNS / args.batch
    summary_csv = batch_dir / "experimento_summary.csv"

    prompts = {arm: path.read_text(encoding="utf-8") for arm, path in ARMS.items()}
    sha8 = {arm: hashlib.sha256(p.encode("utf-8")).hexdigest()[:8] for arm, p in prompts.items()}
    schedule = arm_schedule(tuple(ARMS), args.k)
    dests = {(arm, i): arm_run_dir(batch_dir, arm, sha8[arm], i) for arm, i, _ in schedule}

    todo = [(arm, i, mode) for arm, i, mode in schedule if not _is_complete(dests[(arm, i)])]
    done = len(schedule) - len(todo)
    wall = sum(15 if m == "full" else 12 for _, _, m in todo)

    print(f"Plano: {len(ARMS)} bracos x {args.k} replicas = {len(schedule)} simulacoes, intercaladas.")
    for arm in ARMS:
        modes = [m for a, _, m in schedule if a == arm]
        print(f"  {arm:9s} sha8={sha8[arm]}  {modes.count('full')} full + {modes.count('light')} light")
    if sha8["p0"] != sha8["p0_prime"]:
        print("❌ p0 e p0_prime deveriam ser o MESMO prompt.", file=sys.stderr)
        return 2
    print(f"  ja completas (serao puladas): {done}   a rodar: {len(todo)}")
    print(f"  custo estimado: ~${len(todo) * COST_PER_SIM_USD:.2f} (OpenRouter, gemini-2.5-flash)")
    print(f"  parede estimada: ~{wall} min (~{wall / 60:.1f} h)   [full~15, light~12]")
    print(f"  destino: {batch_dir}/<braco>/r_<sha8>_<i>   resumo: {summary_csv}")

    if not args.go:
        print("\n(DRY) nada foi rodado. Re-execute com --go pra disparar.")
        return 0

    problems = preflight()
    if not P1.exists():
        problems.append(f"prompt p1 ausente: {P1}")
    if problems:
        print("\n❌ pre-checagem falhou:")
        for p in problems:
            print("   -", p)
        return 1

    from hefesto.grader.stability_grader import StabilityGrader
    from hefesto.runner.wasp_runner import WASPRunner, RunnerError
    from hefesto.schemas.core import Objective, Output, TestCase

    grader, obj = StabilityGrader(), Objective(goal="stability")
    rows = []  # (arm, i, mode, S|None, migr|None, csv|erro)

    for n, (arm, i, mode) in enumerate(schedule, 1):
        dest = dests[(arm, i)]
        tag = f"[{n:02d}/{len(schedule)}] {arm}#{i}"
        if _is_complete(dest):
            csv = _existing_csv(dest)
            S = grader.grade(TestCase(input=""), Output(text=str(csv), metadata={"csv": str(csv)}), obj).scores["stability"]
            migr = _migrations(csv)
            print(f"{tag} pulada (ja completa) S={S:.4f}")
            rows.append((arm, i, mode, S, migr, str(csv)))
            continue

        print(f"{tag} rodando ({mode}, ~{15 if mode == 'full' else 12}min)...", flush=True)
        runner = WASPRunner(SIM, CONFIG, dest.parent, reset_mode=mode)
        try:
            out = runner.run(prompts[arm],
                             TestCase(input="", metadata={"arm": arm, "replica": i, "reset_mode": mode}))
        except RunnerError as e:
            print(f"{tag} ❌ FALHOU: {e}  (registrada, seguindo)")
            rows.append((arm, i, mode, None, None, f"ERRO: {e}"))
            continue
        S = grader.grade(TestCase(input=""), out, obj).scores["stability"]
        migr = _migrations(out.metadata["csv"])
        print(f"{tag} ✓ S={S:.4f}  migr={migr:.0f}  [{_classify(migr)}]")
        rows.append((arm, i, mode, S, migr, out.metadata["csv"]))

    batch_dir.mkdir(parents=True, exist_ok=True)
    with open(summary_csv, "w", newline="") as f:
        w = csvmod.writer(f)
        w.writerow(["arm", "replica", "reset_mode", "S", "migrations", "mode_class", "csv_ou_erro"])
        for arm, i, mode, S, migr, ref in rows:
            w.writerow([arm, i, mode, "" if S is None else f"{S:.6f}",
                        "" if migr is None else f"{migr:.2f}", _classify(migr), ref])

    print("\n" + "-" * 60)
    fails = [(a, i) for a, i, _, S, _, _ in rows if S is None]
    stalls = [(a, i) for a, i, _, _, m, _ in rows if _classify(m) == "STALL"]
    print(f"RESUMO — {len(rows) - len(fails)}/{len(schedule)} com S (falhas: {fails or 'nenhuma'})")
    for arm in ARMS:
        keep = [S for a, _, _, S, m, _ in rows if a == arm and S is not None and _classify(m) == "normal"]
        allS = [S for a, _, _, S, _, _ in rows if a == arm and S is not None]
        if allS:
            print(f"  {arm:9s} n={len(allS):2d} mean={st.mean(allS):.4f}   "
                  f"pos-exclusao n={len(keep):2d} " +
                  (f"mean={st.mean(keep):.4f} std={st.pstdev(keep):.4f}" if len(keep) > 1 else ""))
    if stalls:
        print(f"\n  🛑 TRIPWIRE: {len(stalls)} run(s) STALL (migr==0): {stalls}")
        print("     O fix do zero-ciclo NAO segurou. Pre-registro §3: parar e investigar")
        print("     antes de confiar na fila.")
    else:
        print("\n  ✓ tripwire limpo: nenhuma run com migr==0.")
    print(f"  resumo salvo em {summary_csv}")
    print("  Analise: PRE-REGISTRO-workshop.md §4a (resampling), §4b (media-S), §4c (thrash),")
    print("           Adendo 1 (decomposicao de S por componente).")
    print("-" * 60)
    return 0


if __name__ == "__main__":
    sys.exit(main())
