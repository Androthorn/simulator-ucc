#!/usr/bin/env python3
"""Passo 0 do brief: medir a parede de um ciclo LLM completo (grafo v2) a partir
dos ai-engine.log das runs existentes. Nao dispara nada, so le os logs.

Ciclo = de "Fetching metrics from MONITOR" ate a ultima linha de recomendacao
(emoji lampada) daquele ciclo. Tambem mede o sub-trecho consolidator."""
import re, glob, os, statistics as st
from pathlib import Path
from datetime import datetime

ANSI = re.compile(r'\x1b\[[0-9;]*m')
TS = re.compile(r'^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]')

def parse(line):
    line = ANSI.sub('', line)
    m = TS.match(line)
    if not m:
        return None, line
    return datetime.strptime(m.group(1), '%Y-%m-%d %H:%M:%S'), line

def cycles_from_log(path):
    """Retorna lista de dicts: fetch, cost_perf_done, consol_start, consol_done, rec_done."""
    events = []
    for raw in open(path, encoding='utf-8', errors='replace'):
        ts, line = parse(raw)
        if ts is None:
            continue
        events.append((ts, line))
    cycles = []
    cur = None
    for ts, line in events:
        if 'Fetching metrics from MONITOR' in line:
            if cur:
                cycles.append(cur)
            cur = {'fetch': ts, 'consol_start': None, 'rec_done': None, 'completions': []}
        elif cur is not None:
            if 'consolidator_agent' in line and 'Loaded prompt' in line:
                cur['consol_start'] = ts
            elif 'chat/completions' in line:
                cur['completions'].append(ts)
            elif '\U0001f4a1' in line or 'Workload default/' in line:
                cur['rec_done'] = ts  # ultima ganha
    if cur:
        cycles.append(cur)
    return cycles

def secs(a, b):
    return (b - a).total_seconds() if a and b else None

# needs the raw runs from the Zenodo archive, extracted at the repository root (runs/ is gitignored)
logs = sorted(glob.glob(str(Path(__file__).resolve().parents[2] / 'runs/A1/*/sim/logs/ai-engine.log')))
print(f"runs A1 encontradas: {len(logs)}\n")

full_walls = []      # fetch -> rec_done (ciclo completo)
consol_walls = []    # consol_start -> rec_done
cycles_per_run = []

for path in logs:
    run = path.split('/runs/A1/')[1].split('/')[0].replace('google-gemini-2.5-flash_', '')
    cs = cycles_from_log(path)
    cycles_per_run.append(len(cs))
    for c in cs:
        w = secs(c['fetch'], c['rec_done'])
        cw = secs(c['consol_start'], c['rec_done'])
        if w: full_walls.append(w)
        if cw: consol_walls.append(cw)

def summ(name, xs):
    xs = [x for x in xs if x is not None]
    if not xs:
        print(f"{name}: (vazio)"); return
    xs.sort()
    p50 = st.median(xs)
    p90 = xs[int(0.9*(len(xs)-1))]
    print(f"{name}: n={len(xs)}  min={min(xs):.0f}s  p50={p50:.0f}s  "
          f"mean={st.mean(xs):.0f}s  p90={p90:.0f}s  max={max(xs):.0f}s")

print(f"ciclos por run (A1, n={len(logs)}): {cycles_per_run}")
print(f"  media ciclos/run = {st.mean(cycles_per_run):.1f}\n")
summ("CICLO COMPLETO (fetch->rec)", full_walls)
summ("so consolidator (load->rec)", consol_walls)

print("\n--- interpretacao passo 0 ---")
if full_walls:
    med = st.median(full_walls)
    print(f"ciclo mediano ~{med:.0f}s.")
    print(f"scheduler 60s {'NAO fecha (ciclo>50s)' if med > 50 else 'fecha'} -> "
          f"{'cenario vira 8-10min, scheduler 90-100s' if med > 50 else '5min viavel'}")
