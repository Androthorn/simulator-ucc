# paper/data: slim per-run data behind the paper

Everything the scripts in `paper/analysis/` read. It mirrors the layout of the raw runs, but keeps only the files the analysis opens: `provenance.json`, the per-run config, and `analyzer/summary/summary_metrics_*.csv` (per-metric mean, min, max, std and median over the run). The raw runs (`metrics.json`, logs, plots; about 850 MB) are in the Zenodo archive linked from the top-level README. All files here are stored byte-exact (`-text` in `.gitattributes`).

| directory | what | runs | dates |
|---|---|---|---|
| `old_runs/outputSummary/output/combined_summaries.csv` | per-run metric summaries of Phase 1 and Phase 2 | 140 | 2026-01 to 2026-03 |
| `old_runs/output/<run>/config_used.yaml` | the configuration each of those runs used, including `consolidator_prompt_file` | 140 | idem |
| `runs/A1`, `A2`, `B1`, `B2` | confirmatory blocks: gemini p0 and p4 (30 each), haiku p0 and p4 (10 each) | 80 | 2026-07-14 to 2026-07-17 |
| `runs-workshop/experimento/` | live experiment: arms `p0`, `p0_prime` (null control), `p1` (the paper's p_fs), 12 each, plus `experimento_summary.csv` | 36 | 2026-07-20 to 2026-07-21 |
| `runs-workshop/p0_batch/`, `p0_clean/`, `p0_smoke_prefila/`, `p0_light_cert/`, `diag/`, `r_8840d32d_1/` | calibration and smoke runs of the compressed scenario | 19 | 2026-07-18 to 2026-07-20 |
| `phase2-adrs/` | the ADRS databases and prompt files of Phase 2 (below) | | 2026-02 to 2026-03 |

`provenance.json` of each confirmatory and live run records the sha256 of the prompt, config and input actually used. `ucc_stats.py` refuses a run whose prompt hash differs from its block's.

`runs-workshop/experimento/experimento_summary.csv` records, in column `csv_ou_erro`, the absolute path each summary had on the author's machine. The scripts use only the part after `runs-workshop/experimento/`.

## phase2-adrs/

`adrs.db` and `adrs_history.db` are the SQLite stores of the ADRS refinement loop (the earlier version of Hefesto, tag `v0.1.0` in github.com/Androthorn/hefesto). Table `evaluations` holds the score the refiner read at each step; `refinements` the step itself; `prompts.user_prompt` the generated texts. Timestamps in `evaluations` and `refinements` are local time (UTC-3); `prompts.created_at` is UTC, the same clock as the run logs.

The Phase 2 prompt files (`consolidator_agent_v2.txt` to `_v6.txt`) were never versioned. What survives:

| file | content | note |
|---|---|---|
| `p0_baseline.txt` | p0, the manual baseline (v1), CRLF | the LF version is what ran (sha256 prefix `8840d32d`) |
| `p1_score0.6281.txt`, `p3_score0.5804.txt` | **the p0 text, not p1 or p3** | extracted from `evaluations.prompt_text`, which stores the base agent's prompt; the names are wrong, the files are kept as found |
| `p2_score0.7364.txt` | the v2 text | equal to `db-prompts/adrs_prompt1_v2.txt` |
| `p4_VENCEDOR_score0.7392.txt` | p4 (v5) as it ran in runs 38 to 47 and in block A2, three few-shot examples | the third example was written by hand (see below) |
| `db-prompts/*.txt` | every text in `prompts.user_prompt`, exported | file names carry the database's own `version` label, which is the output label ADRS assigned, not the paper's p-index |

Mapping of the database prompts to the paper's trajectory (by text length and timestamps): `adrs_prompt1` = p1 (v2), `adrs_prompt2` = p2 (v3), `adrs_prompt3` = p3 (v4), `adrs_prompt4` = p4 (v5) as generated, with two few-shot examples, `adrs_prompt5` = p5 (v6). `adrs_history_prompt1` to `3` are further refinements whose texts match no file known to have run.

**Runs 34 to 37.** They name `consolidator_agent_v5` in their config but are excluded from the p4 batch. The generated v5 (`adrs_prompt4`) has two few-shot examples; the file that ran from run 38 on has three, the third added by hand. The word "churn" first enters the prompts with that third example, and it appears in the logged explanations of 10 of 10 runs 38 to 47, 25 of 30 gemini runs of block A2 and 10 of 10 v6 runs, but in 0 of 40 runs of v1 to v4 and 0 of 4 runs 34 to 37. In the log clock, the two-example v5 was generated at 2026-03-01 20:07, run 34 started at 20:18 and run 38 at 23:19. `paper/analysis/churn_marker.py` reproduces the counts (`churn_by_run.csv`).
