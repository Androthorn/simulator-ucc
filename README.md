# simulator-ucc

Code, data and analysis behind the UCC 2026 paper **"When a Better Prompt Is Just Noise in LLM-Driven Cloud Orchestration"** (Andre Cunha, Giovanni Farias, Fabio Morais; Federal University of Campina Grande).

This repository is a fork of the WASP multi-cluster workload-migration simulator ([cloud-ai-ufcg/simulator](https://github.com/cloud-ai-ufcg/simulator)) with the experiment runners, the pre-registration, the prompts and the analysis of the paper. The original simulator documentation is in [WASP.md](WASP.md). The promotion gate and the refinement tool are in [Androthorn/hefesto](https://github.com/Androthorn/hefesto).

You can regenerate every number in the paper from `paper/data` without running the simulator (section 2). Re-running the simulations needs Docker, a local Kubernetes stack and an OpenRouter key (section 3).

## 1. The three experiments

| experiment | in the paper | dates | runs | runner | ai-engine | data |
|---|---|---|---|---|---|---|
| Phase 1 and Phase 2 (ADRS refinement loop) | Sections IV-A, IV-C, V-A, V-B, V-E | 2026-01 to 2026-03 | 140 | `run_repeated_simulations.sh` | version of the time | `paper/data/old_runs`, `paper/data/phase2-adrs` |
| Confirmatory, gemini p0 vs p4 (30 + 30) and haiku (10 + 10) | Sections IV-D, V-C, V-F | 2026-07-14 to 07-17 | 80 | `run_ucc_experiment.sh` | `7aa416e` (tag `ucc2026-confirmatory`) | `paper/data/runs` |
| Live gate evaluation, p0 / p0' / p_fs, 12 each, compressed scenario | Sections IV-E, V-G | 2026-07-20 to 07-21 | 36 | `run_experiment.py` | `a657919` (tag `ucc2026-live`) | `paper/data/runs-workshop/experimento` |

The `ai-engine` submodule points to [Androthorn/ai-engine-ucc](https://github.com/Androthorn/ai-engine-ucc), branch `ucc2026`, pinned at `a657919`. That fork of [cloud-ai-ufcg/ai-engine](https://github.com/cloud-ai-ufcg/ai-engine) adds three commits on top of `7aa416e`. One of them, `8b7b7e3`, fixes a bug that silently skipped decision cycles in the compressed scenario; the live experiment needs it.

## 2. Regenerating the paper's numbers

```sh
python3 -m venv .venv && .venv/bin/pip install -r paper/requirements.txt
cd paper/analysis
../../.venv/bin/python table1_phase1.py        # Table I
../../.venv/bin/python ucc_stats.py            # Table III, Section V-C, transfer screen
../../.venv/bin/python recon_camera_ready.py   # Tables IV-V numbers, Section V-G, two windows (about 3 min)
```

| in the paper | script | reads |
|---|---|---|
| Table I (Phase 1) | `table1_phase1.py` | `old_runs/.../combined_summaries.csv` |
| Table III, Section V-C | `ucc_stats.py` | `runs/A1..B2` |
| Section V-C, median and MAD null control | `d2_body_null_control.py` | `runs/A1`, `runs/A2` |
| Section V-B, the same prompt in two windows; Table V; Section V-G (exact false-promotion rate, intervals, injected gain, sensitivity to δ_min); power against the reported gain | `recon_camera_ready.py` | `new_runs_scored.csv`, `old_gemini_labeled.csv`, `experimento_summary.csv` |
| Section V-B, which p4 version runs 34 to 37 ran | `churn_marker.py --from-csv` | `churn_by_run.csv` |
| Table IV and the power figure | `make_figures.py` | the CSVs in `paper/analysis` |
| Figure 3 (mixture) and Figure 4 (promotion by k) | `make_figures.py` (writes `paper/figures/`), `replay_gate.py`, `real_gain_gate.py` | idem |
| Section VI-C, sensitivity to the score weights | `weight_sensitivity.py` | `new_runs_scored.csv`, `runs-workshop/experimento` |

All paths are relative to the scripts. The stability score S comes from one function only, `paper/analysis/ucc_scoring.py`. Hefesto carries an audited copy, checked by a cross-test. The scripts were checked against the camera-ready with numpy 2.3.5, pandas 2.3.3, scipy 1.16.3 and matplotlib 3.10.7. `paper/data/README.md` describes every data file, including the known naming errors in the Phase 2 prompt files.

Two scripts need the raw runs, which are not in git: `cycle_latency.py`, and `churn_marker.py` without `--from-csv`. The raw runs are in the Zenodo archive, DOI `TODO`. Extract it at the repository root; `runs/`, `runs-workshop/` and `old_runs/` are gitignored there.

## 3. Running the simulations

Requirements: Docker, Go, kind, Karmada and KWOK (installed by `scripts/install_*.sh`), Python 3.10+, and an OpenRouter API key. The runners call `sudo` for the cluster setup.

```sh
git clone --recurse-submodules https://github.com/Androthorn/simulator-ucc.git
cd simulator-ucc
cp ai-engine/.env.example ai-engine/.env      # set OPENROUTER_API_KEY; the file is gitignored
```

- **One replica, compressed scenario (about 13 min):** `RESET_MODE=full bash run_one_replica.sh <prompt_name> simulator/data/config_compressed.yaml <dest_dir>`. Use `--dry` first.
- **Confirmatory queue (30 min per run):** `bash run_ucc_experiment.sh --dry-run`, then `--run`. It interleaves the arms, refuses any run whose prompt sha256 differs from its block's, and writes `provenance.json` per run. It snapshots `simulator/data/config.yaml` to `config.yaml.ucc_canonical` and restores it between runs.
- **Live experiment (three arms, 12 replicas each):** needs Hefesto installed in the same Python (`pip install -e <hefesto checkout>`). Run `python run_experiment.py` for the plan and the cost, then `--go`.

Measured cost: about US$0.20 to 0.26 of OpenRouter usage per simulation with gemini-2.5-flash, and 13 min (compressed) or 40 min (full) of wall-clock time.

## 4. Provenance

- **Pre-registration of the live experiment:** `PRE-REGISTRO-workshop.md` (in Portuguese). Its body and addenda 1 and 2 were committed before the queue started (2026-07-20 18:15); addenda 3 and 4 record the results and deviations. Tags: `prereg-body` (`5dcf2a7`), `prereg-addendum-1` (`beae8cb`), `prereg-addendum-2` (`f300d38`), `prereg-addendum-3` (`e341776`), `prereg-addendum-4` (`66ba67d`). The addenda are additive; `git diff --numstat` shows no removed lines.
- **The confirmatory experiment** was pre-specified in `paper/PLANO-UCC-experimentos.md`, dated 2026-07-13, the day before the first run. That plan was not under version control at the time, so its date cannot be verified by a third party. The paper says so.
- **Prompts:** `prompts-experimento/` holds byte-exact copies, stored with `-text`.

  | file | sha256 prefix | role |
  |---|---|---|
  | `cand_8840d32d.txt` | `8840d32d362ee1ef` | p0 as delivered to the model (LF); names every live replica `r_8840d32d_*` |
  | `consolidator_agent_p0.txt` | `dd68a9989439e79f` | p0 file on disk (CRLF); the hash recorded by the confirmatory runs |
  | `consolidator_agent_p1.txt` | `35c8905da31e74c3` | p_fs (`p1` in the code), p0 plus two few-shot examples of p4 |
  | `consolidator_agent_p4.txt` | `e46c69aa5b343752` | p4, the Phase 2 winner; two examples generated by ADRS, one written by hand |

- **Per run:** `provenance.json` records the sha256 of the prompt, config and input actually used.

## 5. Known limits

- Phase 2 used `gemini-3.1-pro-preview` as the refiner. Preview models get withdrawn, so the trajectory itself cannot be re-generated. Its outputs are in `paper/data/phase2-adrs`.
- The agents call hosted LLMs. Provider-side changes can move the score distribution between windows. Between the Phase 1 batch of p0 (2026-01-29/30) and block A1 (July) the paper detects no drift (Welch p = 0.43).
- Simulation removes infrastructure noise. The dispersion of S reported here is a lower bound for a live cluster.

## 6. License and citation

Apache License 2.0, as upstream; see [LICENSE](LICENSE) and [NOTICE](NOTICE). For the citation, see [CITATION.cff](CITATION.cff).
