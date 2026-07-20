#!/usr/bin/env python3
"""Smoke de 1 réplica — prova o pipeline comprimido ponta a ponta com sim REAL.

WASPRunner (prompt p0 → prompts/workshop) → run_one_replica.sh (SIM_CONFIG_SRC →
infra com config_compressed) → sim WASP ~10min (input_compressed 600s) →
summary_metrics.csv → StabilityGrader → S.

NÃO é loop, não promove nada. Só valida a fiação com uma sim de verdade.
Custa créditos (1 sim, gemini-2.5-flash) e usa sudo (make setup-and-start).

Rodar:  cd /home/andre/projetos && hefesto/.venv/bin/python smoke_1_replica.py
"""
import os
import sys
from pathlib import Path

ROOT = Path("/home/andre/projetos")
SIM = ROOT / "simulatormeu"
CONFIG = SIM / "simulator" / "data" / "config_compressed.yaml"
INPUT = SIM / "simulator" / "data" / "input_compressed.json"
RUNS = SIM / "runs-workshop"
P0 = SIM / "ai-engine" / "prompts" / "consolidator_agent_p0.txt"
ENV = SIM / "ai-engine" / ".env"


def preflight() -> list[str]:
    problems = []
    if not CONFIG.exists():
        problems.append(f"config comprimido ausente: {CONFIG}")
    if not INPUT.exists():
        problems.append(f"input comprimido ausente: {INPUT}")
    if not P0.exists():
        problems.append(f"prompt p0 ausente: {P0}")
    # OPENROUTER_API_KEY em ai-engine/.env (o make/ai-engine exige)
    key = ""
    if ENV.exists():
        for line in ENV.read_text().splitlines():
            if line.startswith("OPENROUTER_API_KEY="):
                key = line.split("=", 1)[1].strip()
    if not key:
        problems.append(f"OPENROUTER_API_KEY vazio/ausente em {ENV}")
    if os.system("command -v docker >/dev/null 2>&1") != 0:
        problems.append("docker não encontrado no PATH")
    return problems


def main() -> int:
    from hefesto.runner.wasp_runner import WASPRunner, RunnerError
    from hefesto.grader.stability_grader import StabilityGrader
    from hefesto.schemas.core import TestCase, Objective

    problems = preflight()
    if problems:
        print("❌ pré-checagem falhou:")
        for p in problems:
            print("   -", p)
        print("\nResolva os itens acima antes de rodar (gate 1 + créditos + env).")
        return 1

    print("✅ pré-checagem ok. Disparando 1 réplica REAL (~10 min, sudo + créditos)...\n")
    RUNS.mkdir(exist_ok=True)
    prompt = P0.read_text(encoding="utf-8")  # candidato = texto do p0

    runner = WASPRunner(SIM, CONFIG, RUNS, reset_mode="full")
    grader = StabilityGrader()
    case = TestCase(input="", metadata={"replica": 1})

    try:
        out = runner.run(prompt, case)
    except RunnerError as e:
        print(f"❌ réplica falhou: {e}")
        return 2

    metrics = grader.grade(case, out, Objective(goal="stability"))
    S = metrics.scores["stability"]
    print("\n────────────────────────────────────────")
    print(f"✅ SMOKE OK — pipeline fechou ponta a ponta")
    print(f"   S = {S:.4f}")
    print(f"   run_dir   = {out.metadata['run_dir']}")
    print(f"   csv       = {out.metadata['csv']}")
    print(f"   provenance= {out.metadata['provenance']}")
    print("────────────────────────────────────────")
    return 0


if __name__ == "__main__":
    sys.exit(main())
