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
CANONICAL="${CONFIG_PATH}.replica_canonical"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
die() { echo "❌ FATAL: $*" >&2; exit 1; }
sha_of() { sha256sum "$1" | awk '{print $1}'; }

[ "${RESET_MODE}" = "light" ] && die "RESET_MODE=light ainda NÃO validado (gate 1). Use full."
[ "${RESET_MODE}" = "full" ] || die "RESET_MODE inválido: ${RESET_MODE}"

# snapshot canônico do config comprimido (uma vez) p/ restauração
[ -f "${CANONICAL}" ] || cp "${CONFIG_PATH}" "${CANONICAL}"
restore_config() { cp "${CANONICAL}" "${CONFIG_PATH}"; }
trap restore_config EXIT

# aponta o prompt candidato via config (nunca edita txt ativo) — mesma linha do run_one_real
apply_prompt() {
  yq -i '.["ai-engine"].ai.multi_agent.prompts.consolidator_prompt_file = "'"${PROMPT_NAME}"'"' "${CONFIG_PATH}"
}

write_provenance() { # $1=status
  local pf="${PROMPTS_DIR}/${PROMPT_NAME}.txt"
  local psha; psha="$(sha_of "${pf}")"
  local csha; csha="$(sha_of "${CONFIG_PATH}")"
  local isha; isha="$(sha_of "${ROOT_DIR}/simulator/data/input_const.json" 2>/dev/null || echo NA)"
  local model; model="$(yq -r '.["ai-engine"].ai.selected_model // "unknown"' "${CONFIG_PATH}")"
  mkdir -p "${DEST}"
  jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg st "$1" \
        --arg pn "${PROMPT_NAME}.txt" --arg ps "${psha}" --arg cs "${csha}" \
        --arg is "${isha}" --arg md "${model}" --arg rm "${RESET_MODE}" \
    '{timestamp:$ts,status:$st,reset_mode:$rm,model:$md,
      prompt:{file:$pn,sha256:$ps},config:{sha256:$cs},input:{sha256:$is},
      script:"run_one_replica.sh"}' > "${DEST}/provenance.json"
}

restore_config
apply_prompt
[ -f "${PROMPTS_DIR}/${PROMPT_NAME}.txt" ] || die "prompt não existe: ${PROMPT_NAME}.txt (loader devolveria vazio)"

if [ "${DRY}" -eq 1 ]; then
  write_provenance "planned"
  log "dry: provenance planned em ${DEST}"
  exit 0
fi

# --- execução real (RESET_MODE=full): reusa a mecânica do run_one_real ---
cp "${ROOT_DIR}/simulator/data/input_const.json" "${ROOT_DIR}/simulator/data/input.json"
before="$(ls -1dt "${ROOT_DIR}/simulator/data/output"/*/ 2>/dev/null | head -1 || true)"
sudo -E CONFIG_OVERRIDE="${CONFIG_PATH}" make -C "${ROOT_DIR}" setup-and-start || die "setup-and-start falhou"
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
