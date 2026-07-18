#!/usr/bin/env bash
# run_one_replica.sh — UMA réplica de sim comprimida para o loop do workshop.
# Deriva de run_ucc_experiment.sh:run_one_real (mecânica idêntica), SEM o gate
# de sha p0/p4 e SEM a fila. Prompt já escrito pelo WASPRunner; aqui só aponta
# via config, roda, coleta e grava provenance (write-then-record do sha).
# Uso: run_one_replica.sh [--dry] <prompt_name> <config_path> <dest_dir>
#      env: RESET_MODE=full|light   (default full)
set -uo pipefail

DRY=0; [ "${1:-}" = "--dry" ] && { DRY=1; shift; }
PROMPT_NAME="${1:?prompt_name}"; CONFIG_PATH="${2:?config_path}"; DEST="${3:?dest_dir}"
RESET_MODE="${RESET_MODE:-full}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPTS_DIR="${ROOT_DIR}/ai-engine/prompts"
DATA_DIR="${ROOT_DIR}/simulator/data"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
die() { echo "❌ FATAL: $*" >&2; exit 1; }
sha_of() { sha256sum "$1" | awk '{print $1}'; }

[ "${RESET_MODE}" = "light" ] && die "RESET_MODE=light ainda NÃO validado (gate 1). Use full."
[ "${RESET_MODE}" = "full" ] || die "RESET_MODE inválido: ${RESET_MODE}"

# Cópia de trabalho por-réplica: o config base (config_compressed.yaml) NUNCA é mutado
# in-place — assim edições no base (ex.: input_json) não são revertidas, e cada réplica
# guarda o config exato que usou em ${DEST}/config.used.yaml (bom p/ provenance/rigor).
mkdir -p "${DEST}"
WORK_CFG="${DEST}/config.used.yaml"
cp "${CONFIG_PATH}" "${WORK_CFG}" || die "não consegui copiar config base p/ ${WORK_CFG}"

# aponta o prompt candidato NA CÓPIA (via config, nunca editando o txt ativo)
yq -i '.["ai-engine"].ai.multi_agent.prompts.consolidator_prompt_file = "'"${PROMPT_NAME}"'"' "${WORK_CFG}" \
  || die "apply_prompt (yq) falhou — config não repontado"

write_provenance() { # $1=status
  local pf="${PROMPTS_DIR}/${PROMPT_NAME}.txt"
  local psha; psha="$(sha_of "${pf}")"
  local csha; csha="$(sha_of "${WORK_CFG}")"
  local ifile="${INPUT_FILE:-input_const.json}"
  local isha; isha="$(sha_of "${DATA_DIR}/${ifile}" 2>/dev/null || echo NA)"
  local model; model="$(yq -r '.["ai-engine"].ai.selected_model // "unknown"' "${WORK_CFG}")"
  mkdir -p "${DEST}"
  jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg st "$1" \
        --arg pn "${PROMPT_NAME}.txt" --arg ps "${psha}" --arg cs "${csha}" \
        --arg if "${ifile}" --arg is "${isha}" --arg md "${model}" --arg rm "${RESET_MODE}" \
    '{timestamp:$ts,status:$st,reset_mode:$rm,model:$md,
      prompt:{file:$pn,sha256:$ps},config:{sha256:$cs},input:{file:$if,sha256:$is},
      script:"run_one_replica.sh"}' > "${DEST}/provenance.json"
}

[ -f "${PROMPTS_DIR}/${PROMPT_NAME}.txt" ] || die "prompt não existe: ${PROMPT_NAME}.txt (loader devolveria vazio)"

# input vem do config (data.input_json), não hardcodado — permite o input comprimido do workshop.
INPUT_FILE="$(yq -r '.["ai-engine"].data.input_json // "input_const.json"' "${WORK_CFG}")"
[ -f "${DATA_DIR}/${INPUT_FILE}" ] || die "input não existe: ${INPUT_FILE}"

if [ "${DRY}" -eq 1 ]; then
  write_provenance "planned"
  log "dry: provenance planned em ${DEST}"
  exit 0
fi

# --- execução real (RESET_MODE=full): reusa a mecânica do run_one_real ---
cp "${DATA_DIR}/${INPUT_FILE}" "${DATA_DIR}/input.json"
before="$(ls -1dt "${DATA_DIR}/output"/*/ 2>/dev/null | head -1 || true)"
# SIM_CONFIG_SRC (path ABSOLUTO da cópia de trabalho) é honrado por compose.yaml e main.sh
# (Route A: infra parametrizada; default = config.yaml congelada quando a var não é setada).
WORK_CFG_ABS="$(readlink -f "${WORK_CFG}")"
sudo -E SIM_CONFIG_SRC="${WORK_CFG_ABS}" make -C "${ROOT_DIR}" setup-and-start || die "setup-and-start falhou"
last="$(ls -1dt "${ROOT_DIR}/simulator/data/output"/*/ 2>/dev/null | head -1 || true)"
[ -n "${last}" ] && [ "${last}" != "${before}" ] && [ -f "${last%/}/metrics.json" ] || die "sim sem output novo"
ts="$(basename "${last%/}")"
(cd "${ROOT_DIR}/analyzer" && make generate-plots "${ts}") || die "analyzer falhou"
mkdir -p "${DEST}/sim" "${DEST}/analyzer"
sudo cp -r "${last%/}/." "${DEST}/sim/" 2>/dev/null || true
sudo cp -r "${ROOT_DIR}/analyzer/output/${ts}/." "${DEST}/analyzer/" 2>/dev/null || true
sudo chown -R "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "${DEST}" 2>/dev/null || true
write_provenance "complete"
log "réplica completa → ${DEST}"
