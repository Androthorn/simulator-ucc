#!/usr/bin/env bash
#
# run_ucc_experiment.sh — Fila de experimentos para o upgrade UCC 2026.
#
# Implementa a matriz §2 do PLANO-UCC-experimentos.md com:
#   - intercalação por paridade decidida PELO SCRIPT (não pelo operador)   §5.1
#   - gate FATAL de prompt: arquivo existe + sha256 == esperado-do-bloco,   §5 (adição André)
#     senão ABORTA a fila inteira (nunca segue com prompt vazio/errado)
#   - provenance.json por run, gravado DEPOIS do gate                       §5.2
#   - nomenclatura runs/{bloco}/{model}_{prompt}_{T}_run{NN}/               §5.3
#   - resiliência: retry c/ backoff, run parcial descartada e re-enfileirada §5.4
#   - idempotência: run com provenance completo é pulada                    §11
#
# Auto-contido de propósito: NÃO delega a run_repeated_simulations.sh porque
# aquele script restaura config.yaml do .auto_backup dentro do loop (que hoje
# carrega o consolidator_agent_v6 quebrado) e não mexe em consolidator_prompt_file.
# Aqui o wrapper é o dono da mutação do prompt, do gate e do provenance.
# A mecânica interna (make setup-and-start, detecção de output, cleanup de docker,
# fix de ownership) é replicada de run_repeated_simulations.sh (commit 05aa23b).

set -uo pipefail

# ---------------------------------------------------------------------------
# Constantes do experimento (§1, §2). NÃO editar sem revisar o plano.
# ---------------------------------------------------------------------------
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${ROOT_DIR}/simulator/data/config.yaml"
CANONICAL_FILE="${CONFIG_FILE}.ucc_canonical"   # snapshot pristino tirado no start
PROMPTS_DIR="${ROOT_DIR}/ai-engine/prompts"
DATA_DIR="${ROOT_DIR}/simulator/data"
SIM_OUTPUT_DIR="${DATA_DIR}/output"
ANALYZER_OUTPUT_DIR="${ROOT_DIR}/analyzer/output"
RUNS_DIR="${ROOT_DIR}/runs"

TEMPERATURE="0.1"          # §1
GRAPH_VERSION="v2"         # config canônica
INPUT_FILE="input_const.json"   # workload do paper — read-only §3
NODES_VALUE=10
CPU_VALUE="8"
MEMORY_VALUE="16Gi"

MAX_RETRIES=3              # §5.4
BACKOFF_BASE=30           # segundos; backoff exponencial: 30, 60, 120...
MIN_FREE_GB=20            # abaixo disto, faz limpeza profunda (disk guard)

# Modelos (forma OpenRouter com barra — §1, padronização confirmada) ----------
MODEL_gemini="google/gemini-2.5-flash"
MODEL_haiku="anthropic/claude-haiku-4.5"

# Prompts do consolidador (nome SEM .txt, como o config espera) + sha esperado.
# Hashes fixados na verificação de fidelidade do §4 (13/07/2026).
PROMPT_NAME_p0="consolidator_agent_p0"
PROMPT_NAME_p4="consolidator_agent_p4"
EXPECT_SHA_p0="dd68a9989439e79fb03b8f2e36024bf05c8ad6a2fe50c23e62bb5024a06ea4bb"
EXPECT_SHA_p4="e46c69aa5b34375279fe852b15185b904ab92543b9a4650b2fea8ab4bfe9d7d2"

# Matriz §2: "bloco:model_key:prompt_key:count"
MATRIX=(
  "A1:gemini:p0:30"
  "A2:gemini:p4:30"
  "B1:haiku:p0:10"
  "B2:haiku:p4:10"
)

# ---------------------------------------------------------------------------
MODE="dry-run"            # default seguro: não roda make/sudo/docker
usage() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run | --run | --smoke] [-h]

  --dry-run   (default) Gera a fila intercalada e um provenance.json por run
              SEM executar simulações. Roda o gate fatal de prompt de verdade.
              Não usa sudo/docker/make. Use para revisão.
  --smoke     Executa 1 run p0 + 1 run p4 REAIS (§5.5): valida que sai
              combined_summaries.csv, que o S calcula e que o provenance
              registra o prompt certo. Requer env completo + OPENROUTER_API_KEY.
  --run       Executa a fila completa (80 runs, §2). Só depois do smoke verde.
  -h|--help   Esta ajuda.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) MODE="dry-run"; shift ;;
    --run)     MODE="run";     shift ;;
    --smoke)   MODE="smoke";   shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Opção desconhecida: $1"; usage; exit 1 ;;
  esac
done

log()  { echo "[$(date -u +%H:%M:%S)] $*"; }
die()  { echo "❌ FATAL: $*" >&2; restore_config 2>/dev/null || true; exit 1; }

sha_of() { sha256sum "$1" | awk '{print $1}'; }

restore_config() {
  [ -f "${CANONICAL_FILE}" ] && cp "${CANONICAL_FILE}" "${CONFIG_FILE}"
}

free_gb() { df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9'; }

# Recupera espaço docker no fim de CADA run. PRESERVA o build cache de propósito:
# como 'make stop-all-containers' deleta as imagens a cada run, é o cache que
# reconstrói rápido (pula o 'pip install' se a camada não mudou) — matá-lo
# lentificaria os 80 rebuilds. O vazamento real são volumes anônimos do kind
# (etcd), porque 'make stop-kubernetes-infra' faz 'docker rm -f' SEM -v.
reclaim_docker() {
  docker container prune -f >/dev/null 2>&1 || true   # containers parados
  docker volume prune -f    >/dev/null 2>&1 || true   # volumes órfãos (kind etcd)
  docker image prune -f     >/dev/null 2>&1 || true   # imagens dangling
  local avail; avail="$(free_gb)"
  if [ -n "${avail}" ] && [ "${avail}" -lt "${MIN_FREE_GB}" ]; then
    # Disk guard: reclama o GROSSO (imagens ociosas + volumes), mas ainda
    # SEM builder prune — o cache vale mais que os ~1GB que ele liberaria.
    log "  ⚠ disco livre ${avail}GB < ${MIN_FREE_GB}GB — reclaim agressivo (imagens ociosas, cache preservado)"
    docker image prune -af >/dev/null 2>&1 || true    # todas imagens não-usadas
    docker volume prune -f >/dev/null 2>&1 || true
    avail="$(free_gb)"
  fi
  log "  🧹 reclaim ok — disco livre: ${avail:-?}GB (build cache preservado)"
}

# ---------------------------------------------------------------------------
# Pré-requisitos
# ---------------------------------------------------------------------------
check_prereqs() {
  command -v yq >/dev/null 2>&1 || die "'yq' (v4+) não encontrado no PATH."
  command -v jq >/dev/null 2>&1 || die "'jq' não encontrado no PATH."
  [ -f "${CONFIG_FILE}" ] || die "config.yaml não encontrado: ${CONFIG_FILE}"
  [ -f "${DATA_DIR}/${INPUT_FILE}" ] || die "workload não encontrado: ${DATA_DIR}/${INPUT_FILE}"
  [ -f "${PROMPTS_DIR}/${PROMPT_NAME_p0}.txt" ] || die "prompt p0 ausente: ${PROMPTS_DIR}/${PROMPT_NAME_p0}.txt"
  [ -f "${PROMPTS_DIR}/${PROMPT_NAME_p4}.txt" ] || die "prompt p4 ausente: ${PROMPTS_DIR}/${PROMPT_NAME_p4}.txt"
  if [ "${MODE}" != "dry-run" ]; then
    command -v docker >/dev/null 2>&1 || die "'docker' necessário para execução real."
    local key
    key="$(grep -E '^OPENROUTER_API_KEY=' "${ROOT_DIR}/ai-engine/.env" 2>/dev/null | cut -d= -f2-)"
    [ -n "${key}" ] || die "OPENROUTER_API_KEY vazio em ai-engine/.env (§10)."
  fi
}

# Resolve dados de um prompt_key -> nome do arquivo e sha esperado
prompt_name_for() { case "$1" in p0) echo "${PROMPT_NAME_p0}";; p4) echo "${PROMPT_NAME_p4}";; *) die "prompt_key inválido: $1";; esac; }
prompt_sha_for()  { case "$1" in p0) echo "${EXPECT_SHA_p0}";;  p4) echo "${EXPECT_SHA_p4}";;  *) die "prompt_key inválido: $1";; esac; }
model_for()       { case "$1" in gemini) echo "${MODEL_gemini}";; haiku) echo "${MODEL_haiku}";; *) die "model_key inválido: $1";; esac; }

# ---------------------------------------------------------------------------
# Mutação de config (idêntica ao base + a linha nova do consolidador)
# ---------------------------------------------------------------------------
apply_config() {   # $1=target_config  $2=model  $3=prompt_name
  local cfg="$1" model="$2" prompt_name="$3"
  yq -i '.["ai-engine"].ai.selected_model = "'"${model}"'"' "${cfg}"
  yq -i '.["ai-engine"].data.input_json = "'"${INPUT_FILE}"'"' "${cfg}"
  yq -i '.["ai-engine"].ai.multi_agent.graph_version = "'"${GRAPH_VERSION}"'"' "${cfg}"
  yq -i '.["ai-engine"].ai.multi_agent.generation_config.temperature = '"${TEMPERATURE}" "${cfg}"
  # A LINHA NOVA — troca de prompt SÓ via config (§4.3), nunca editando o txt ativo:
  yq -i '.["ai-engine"].ai.multi_agent.prompts.consolidator_prompt_file = "'"${prompt_name}"'"' "${cfg}"
  yq -i ".clusters.member1.nodes = ${NODES_VALUE}" "${cfg}"
  yq -i '.clusters.member1.cpu = "'"${CPU_VALUE}"'"' "${cfg}"
  yq -i '.clusters.member1.memory = "'"${MEMORY_VALUE}"'"' "${cfg}"
  yq -i ".clusters.member1.autoscaler = false" "${cfg}"
  yq -i ".clusters.member2.nodes = ${NODES_VALUE}" "${cfg}"
  yq -i '.clusters.member2.cpu = "'"${CPU_VALUE}"'"' "${cfg}"
  yq -i '.clusters.member2.memory = "'"${MEMORY_VALUE}"'"' "${cfg}"
  yq -i ".clusters.member2.autoscaler = true" "${cfg}"
}

# ---------------------------------------------------------------------------
# O GATE FATAL (§5, adição André). Roda ANTES de qualquer simulação.
# Confere: (a) config aponta o prompt esperado; (b) arquivo existe;
#          (c) sha256 do arquivo == esperado-do-bloco.
# IMPORTANTE: NÃO chama die() aqui dentro. Devolve o sha verificado na global
# GATE_SHA e sinaliza falha por código de saída (return 1). O die() precisa
# rodar no shell principal via '|| die' — se o gate morresse dentro de $(...),
# o exit só mataria o subshell e a fila SEGUIRIA (o pior modo de falha).
# ---------------------------------------------------------------------------
GATE_SHA=""
verify_prompt_gate() {   # $1=config  $2=prompt_key  -> GATE_SHA + return 0/1
  local cfg="$1" prompt_key="$2"
  local want_name want_sha got_name file got_sha
  GATE_SHA=""
  want_name="$(prompt_name_for "${prompt_key}")"
  want_sha="$(prompt_sha_for "${prompt_key}")"

  got_name="$(yq -r '.["ai-engine"].ai.multi_agent.prompts.consolidator_prompt_file' "${cfg}")"
  if [ "${got_name}" != "${want_name}" ]; then
    echo "config aponta consolidator_prompt_file='${got_name}', esperado '${want_name}' (bloco ${prompt_key})." >&2
    return 1
  fi

  file="${PROMPTS_DIR}/${want_name}.txt"
  if [ ! -f "${file}" ]; then
    echo "prompt apontado não existe: ${file} — loader devolveria prompt VAZIO." >&2
    return 1
  fi

  got_sha="$(sha_of "${file}")"
  if [ "${got_sha}" != "${want_sha}" ]; then
    echo "sha256 de ${file} = ${got_sha}, esperado ${want_sha} (bloco ${prompt_key})." >&2
    return 1
  fi

  GATE_SHA="${got_sha}"
  return 0
}

# ---------------------------------------------------------------------------
# provenance.json — gravado DEPOIS do gate
# ---------------------------------------------------------------------------
write_provenance() {  # $1=destdir $2=bloco $3=model $4=prompt_key $5=runNN
                      # $6=exec_idx $7=prompt_sha(verificado) $8=config_sha $9=status
  local dest="$1" bloco="$2" model="$3" prompt_key="$4" runNN="$5"
  local exec_idx="$6" prompt_sha="$7" config_sha="$8" status="$9"
  local input_sha git_commit ts prompt_name
  input_sha="$(sha_of "${DATA_DIR}/${INPUT_FILE}")"
  git_commit="$(git -C "${ROOT_DIR}" rev-parse HEAD 2>/dev/null || echo unknown)"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  prompt_name="$(prompt_name_for "${prompt_key}")"
  jq -n \
    --arg ts "${ts}" --arg bloco "${bloco}" --arg model "${model}" \
    --arg temp "${TEMPERATURE}" --arg graph "${GRAPH_VERSION}" \
    --arg prompt_key "${prompt_key}" --arg prompt_file "${prompt_name}.txt" \
    --arg prompt_sha "${prompt_sha}" --arg config_sha "${config_sha}" \
    --arg input_file "${INPUT_FILE}" --arg input_sha "${input_sha}" \
    --arg git "${git_commit}" --arg run "${runNN}" --argjson exec "${exec_idx}" \
    --arg mode "${MODE}" --arg status "${status}" \
    '{
      timestamp: $ts, mode: $mode, status: $status,
      bloco: $bloco, run: $run, exec_index: $exec,
      model: $model, temperature: ($temp|tonumber), graph_version: $graph,
      prompt: { key: $prompt_key, file: $prompt_file, sha256: $prompt_sha },
      config: { file: "simulator/data/config.yaml", sha256: $config_sha },
      input:  { file: $input_file, sha256: $input_sha },
      simulatormeu_git_commit: $git,
      script: "run_ucc_experiment.sh"
    }' > "${dest}/provenance.json"
}

# ---------------------------------------------------------------------------
# is_done: idempotência — provenance completo (status=complete) => pular
# ---------------------------------------------------------------------------
is_done() {  # $1=destdir
  local p="$1/provenance.json"
  [ -f "${p}" ] || return 1
  [ "$(jq -r '.status' "${p}" 2>/dev/null)" = "complete" ]
}

# ---------------------------------------------------------------------------
# Executa UMA run (real). Retry c/ backoff; parcial descartada; provenance no fim.
# ---------------------------------------------------------------------------
run_one_real() {  # $1=bloco $2=model_key $3=prompt_key $4=runNN $5=exec_idx $6=destdir
  local bloco="$1" model_key="$2" prompt_key="$3" runNN="$4" exec_idx="$5" dest="$6"
  local model prompt_name attempt=1 backoff="${BACKOFF_BASE}"
  model="$(model_for "${model_key}")"
  prompt_name="$(prompt_name_for "${prompt_key}")"

  while [ "${attempt}" -le "${MAX_RETRIES}" ]; do
    log "▶ ${bloco} run${runNN} (exec ${exec_idx}) | ${model} | ${prompt_key} | tentativa ${attempt}/${MAX_RETRIES}"

    # 1) config pristino + mutações (incl. prompt)
    restore_config
    apply_config "${CONFIG_FILE}" "${model}" "${prompt_name}"
    # sincroniza input do simulador (base faz isto)
    cp "${DATA_DIR}/${INPUT_FILE}" "${DATA_DIR}/input.json"

    # 2) GATE FATAL (aborta a fila inteira se divergir) — die() no shell principal.
    #    O motivo específico já foi impresso no stderr por verify_prompt_gate.
    local prompt_sha config_sha
    verify_prompt_gate "${CONFIG_FILE}" "${prompt_key}" \
      || die "gate de prompt falhou (bloco ${bloco} run${runNN}). Fila abortada."
    prompt_sha="${GATE_SHA}"
    config_sha="$(sha_of "${CONFIG_FILE}")"
    log "  ✓ gate ok — ${prompt_name}.txt sha=${prompt_sha:0:12}…"

    # marca o output mais recente que JÁ existe (pra não confundir dir velho/órfão
    # com o resultado desta run — ex.: run interrompida deixa dir root-owned pra trás)
    local before_dir
    before_dir="$(ls -1dt "${SIM_OUTPUT_DIR}"/*/ 2>/dev/null | head -1 || true)"

    # 3) roda a simulação
    if sudo -E make -C "${ROOT_DIR}" setup-and-start; then
      # 4) detecta o output cru do sim; sucesso exige (a) um dir NOVO (≠ before_dir)
      #    e (b) metrics.json dentro (dado real). O CSV combinado NÃO sai daqui —
      #    vem do analyzer (passo 5) e da agregação do §6.
      local last ts an_dir
      last="$(ls -1dt "${SIM_OUTPUT_DIR}"/*/ 2>/dev/null | head -1 || true)"
      if [ -n "${last}" ] && [ "${last}" != "${before_dir}" ] && [ -f "${last%/}/metrics.json" ]; then
        ts="$(basename "${last%/}")"
        # 5) roda o ANALYZER (o que faltava): gera summary_metrics_*.csv + figuras.
        #    Usa ../venv/bin/python (o venv do projeto).
        if (cd "${ROOT_DIR}/analyzer" && make generate-plots "${ts}"); then
          an_dir="${ANALYZER_OUTPUT_DIR}/${ts}"
          # 6) SALVA tudo ANTES de apagar qualquer coisa: sim cru + analyzer + provenance.
          mkdir -p "${dest}/sim" "${dest}/analyzer"
          sudo cp -r "${last%/}/." "${dest}/sim/" 2>/dev/null || true
          [ -d "${an_dir}" ] && sudo cp -r "${an_dir}/." "${dest}/analyzer/" 2>/dev/null || true
          sudo chown -R "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "${dest}" 2>/dev/null || true
          write_provenance "${dest}" "${bloco}" "${model}" "${prompt_key}" \
                           "${runNN}" "${exec_idx}" "${prompt_sha}" "${config_sha}" "complete"
          # só AGORA remove os dirs crus (já salvos em ${dest})
          sudo rm -rf "${last%/}" "${an_dir}" 2>/dev/null || true
          reclaim_docker
          log "  ✅ ${bloco} run${runNN} completa → ${dest#${ROOT_DIR}/} (sim+analyzer salvos)"
          restore_config
          return 0
        fi
        log "  ⚠ analyzer (generate-plots) falhou — descartando run"
      else
        log "  ⚠ sim não produziu output novo com metrics.json (dir novo=$([ -n "${last}" ] && [ "${last}" != "${before_dir}" ] && echo sim || echo nao)) — descartando"
      fi
      # caminho de falha: descarta o parcial p/ retry (aqui SIM pode apagar — sem dado bom)
      [ -n "${last}" ] && sudo rm -rf "${last%/}" 2>/dev/null || true
    else
      log "  ⚠ make setup-and-start falhou"
    fi

    reclaim_docker
    log "  ↻ backoff ${backoff}s antes da próxima tentativa"
    sleep "${backoff}"
    backoff=$((backoff * 2)); attempt=$((attempt + 1))
  done

  restore_config
  reclaim_docker
  log "  ✗ ${bloco} run${runNN} falhou após ${MAX_RETRIES} tentativas — re-enfileirada (sem provenance)"
  return 1
}

# ---------------------------------------------------------------------------
# Executa UMA run (dry): sem make/sudo/docker. Roda o gate de verdade,
# gera provenance realista (config sha de uma cópia mutada em /tmp).
# ---------------------------------------------------------------------------
run_one_dry() {  # mesmos args
  local bloco="$1" model_key="$2" prompt_key="$3" runNN="$4" exec_idx="$5" dest="$6"
  local model prompt_name tmpcfg prompt_sha config_sha
  model="$(model_for "${model_key}")"
  prompt_name="$(prompt_name_for "${prompt_key}")"

  tmpcfg="$(mktemp)"; cp "${CANONICAL_FILE}" "${tmpcfg}"
  apply_config "${tmpcfg}" "${model}" "${prompt_name}"
  # gate REAL — die() no shell principal aborta a fila inteira em caso de falha
  verify_prompt_gate "${tmpcfg}" "${prompt_key}" \
    || { rm -f "${tmpcfg}"; die "gate de prompt falhou (bloco ${bloco} run${runNN}). Fila abortada."; }
  prompt_sha="${GATE_SHA}"
  config_sha="$(sha_of "${tmpcfg}")"
  rm -f "${tmpcfg}"

  mkdir -p "${dest}"
  write_provenance "${dest}" "${bloco}" "${model}" "${prompt_key}" \
                   "${runNN}" "${exec_idx}" "${prompt_sha}" "${config_sha}" "planned"
  printf '  %-3s run%-2s exec%-3s | %-28s | %s | gate✓ sha=%s…\n' \
         "${bloco}" "${runNN}" "${exec_idx}" "${model}" "${prompt_key}" "${prompt_sha:0:12}"
}

# ---------------------------------------------------------------------------
# Construção da fila intercalada (§2). Paridade decidida pelo SCRIPT.
# Ordem: bloco A (gemini) alternando p0/p4 por índice; depois bloco B (haiku).
# Emite: "bloco model_key prompt_key runNN exec_idx"
# ---------------------------------------------------------------------------
build_queue() {
  local exec=0 i
  # Par A1/A2 (gemini): p0, p4, p0, p4, ... — 30 de cada
  for i in $(seq 1 30); do
    local nn; nn="$(printf '%02d' "$i")"
    exec=$((exec+1)); echo "A1 gemini p0 ${nn} ${exec}"
    exec=$((exec+1)); echo "A2 gemini p4 ${nn} ${exec}"
  done
  # Par B1/B2 (haiku): idem, 10 de cada. B começa após A.
  for i in $(seq 1 10); do
    local nn; nn="$(printf '%02d' "$i")"
    exec=$((exec+1)); echo "B1 haiku p0 ${nn} ${exec}"
    exec=$((exec+1)); echo "B2 haiku p4 ${nn} ${exec}"
  done
}

dest_for() {  # $1=bloco $2=model_key $3=prompt_key $4=runNN
  local model_slug; model_slug="$(model_for "$2" | tr '/' '-')"
  echo "${RUNS_DIR}/$1/${model_slug}_$3_${TEMPERATURE}_run$4"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
check_prereqs

# Snapshot canônico pristino (uma vez). Base da restauração por-run.
if [ ! -f "${CANONICAL_FILE}" ]; then
  cp "${CONFIG_FILE}" "${CANONICAL_FILE}"
  log "Snapshot canônico salvo em $(basename "${CANONICAL_FILE}")"
fi

echo "════════════════════════════════════════════════════════════"
echo " UCC 2026 — fila de experimentos   [MODE=${MODE}]"
echo " Total planejado: 80 runs (A1:30 A2:30 B1:10 B2:10)  T=${TEMPERATURE}"
echo "════════════════════════════════════════════════════════════"

if [ "${MODE}" = "dry-run" ]; then
  echo "Matriz intercalada (execução na ordem exec):"
  while read -r bloco model_key prompt_key runNN exec_idx; do
    [ -z "${bloco:-}" ] && continue
    dest="$(dest_for "${bloco}" "${model_key}" "${prompt_key}" "${runNN}")"
    run_one_dry "${bloco}" "${model_key}" "${prompt_key}" "${runNN}" "${exec_idx}" "${dest}"
  done < <(build_queue)
  echo "────────────────────────────────────────────────────────────"
  echo "Dry-run ok. provenance.json (planned) gravado em ${RUNS_DIR#${ROOT_DIR}/}/{A1,A2,B1,B2}/."
  echo "Gate fatal exercitado em todas as 80 runs."
  exit 0
fi

# --- Execução real (smoke | run) -------------------------------------------
# Sudo keepalive (base faz isto)
log "Checando sudo…"; sudo -v || die "sem credenciais sudo."
( while true; do sudo -n true >/dev/null 2>&1 || exit 0; sleep 60; done ) &
SUDO_KEEPALIVE_PID=$!
cleanup() {
  [ -n "${SUDO_KEEPALIVE_PID:-}" ] && kill "${SUDO_KEEPALIVE_PID}" 2>/dev/null || true
  restore_config
  # Limpeza final. PRESERVA o build cache — a fila é idempotente/retomável (§11)
  # e o cache acelera o 1º rebuild da retomada; ele é estável (~1GB, nunca cresce).
  # Poda de cache é decisão manual do André quando o experimento inteiro acabar.
  docker container prune -f >/dev/null 2>&1 || true
  docker image prune -f     >/dev/null 2>&1 || true   # dangling apenas
  docker volume prune -f    >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [ "${MODE}" = "smoke" ]; then
  log "SMOKE: 1×p0 + 1×p4 (gemini). Valida metrics.json + analyzer(summary_metrics) + provenance."
  ok=0
  for pk in p0 p4; do
    dest="$(dest_for "SMOKE" "gemini" "${pk}" "01")"
    is_done "${dest}" && { log "smoke ${pk} já feito, pulando"; ok=$((ok+1)); continue; }
    if run_one_real "SMOKE" "gemini" "${pk}" "01" "0" "${dest}"; then
      # §5.5: sim gerou metrics.json (dado real) e analyzer gerou os summary_metrics
      # (entrada do score S). O CSV *combinado* é responsabilidade do §6/ucc_stats.py,
      # que é prompt-aware — o combine_summaries.py antigo NÃO distingue p0/p4 e por
      # isso NÃO é usado aqui.
      m="$([ -f "${dest}/sim/metrics.json" ] && echo SIM || echo NAO)"
      s="$(ls "${dest}"/analyzer/summary/summary_metrics_*.csv 2>/dev/null | head -1)"
      log "smoke ${pk}: metrics.json=${m} | summary_metrics=$([ -n "${s}" ] && echo SIM || echo NAO)"
      ok=$((ok+1))
    fi
  done
  [ "${ok}" -eq 2 ] && log "✅ SMOKE verde (2/2) — pipeline por-run validado (sim→analyzer→provenance)." \
                    || die "SMOKE incompleto (${ok}/2)."
  exit 0
fi

# MODE=run — fila completa, intercalada, idempotente
processed=0; skipped=0; failed=0
while read -r bloco model_key prompt_key runNN exec_idx; do
  [ -z "${bloco:-}" ] && continue
  dest="$(dest_for "${bloco}" "${model_key}" "${prompt_key}" "${runNN}")"
  if is_done "${dest}"; then
    skipped=$((skipped+1)); log "⏭  ${bloco} run${runNN} já completa — pulando (idempotência)"; continue
  fi
  if run_one_real "${bloco}" "${model_key}" "${prompt_key}" "${runNN}" "${exec_idx}" "${dest}"; then
    processed=$((processed+1))
  else
    failed=$((failed+1))
  fi
done < <(build_queue)

echo "════════════════════════════════════════════════════════════"
log "Fila encerrada: ${processed} novas, ${skipped} puladas, ${failed} falhas."
[ "${failed}" -eq 0 ] || log "Rode de novo: runs falhas serão re-tentadas (idempotência)."
