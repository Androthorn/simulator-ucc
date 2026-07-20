#!/usr/bin/env bash
# light_reset.sh — RESET_MODE=light: reseta o estado mutável entre réplicas SEM
# rebuildar o karmada (reusa os 3 clusters kind). Ordem importa: workload → nós →
# stores → app. A prova de que ficou limpo é o assert_clean_state.sh (roda depois).
# Uso: light_reset.sh <config_path>
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="${ROOT_DIR}/scripts"
CONFIG_PATH="${1:?config_path}"
[ -f "${CONFIG_PATH}" ] || { echo "❌ RESET: config não existe: ${CONFIG_PATH}" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "❌ RESET: precisa rodar como root (sudo) — o kubeconfig do cluster está em /root/.kube" >&2; exit 1; }

MEMBERS_KUBECONFIG="${MEMBERS_KUBECONFIG:-$HOME/.kube/members.config}"
PROM_ENDPOINTS=("${PROM_MEMBER1:-http://localhost:9090}" "${PROM_MEMBER2:-http://localhost:9091}")
MONGO_DB="ai_engine"; MONGO_COLL="recommendation_history"

log() { echo "[reset $(date -u +%H:%M:%S)] $*"; }

export KUBECONFIG="${MEMBERS_KUBECONFIG}"

# 1) Workload: apaga todo deploy/job/pod de workload (namespace default) nos dois members
for ctx in member1 member2; do
  log "workload delete em ${ctx}/default"
  kubectl --context "${ctx}" -n default delete deployments,jobs,pods --all \
    --ignore-not-found --wait=true --timeout=120s
done

# 2) Nós: apaga TODOS os nós KWOK (limpa os que o autoscaler somou) e re-aplica o baseline
for ctx in member1 member2; do
  log "nós KWOK delete em ${ctx}"
  kubectl --context "${ctx}" delete nodes -l type=kwok \
    --ignore-not-found --wait=true --timeout=120s
done
log "re-aplicando baseline de nós (create_kwok_nodes.sh)"
set -a; source "${SCRIPTS_DIR}/load_config.sh" "${CONFIG_PATH}"; set +a
( cd "${SCRIPTS_DIR}" && ./create_kwok_nodes.sh )

# 3) Prometheus: wipe do TSDB via admin API (enableAdminAPI:true; storage é emptyDir)
for url in "${PROM_ENDPOINTS[@]}"; do
  log "wipe TSDB ${url}"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X POST \
    --data-urlencode 'match[]={__name__=~".+"}' \
    "${url}/api/v1/admin/tsdb/delete_series")" \
    || { echo "❌ RESET: delete_series curl falhou em ${url} (inacessível?)" >&2; exit 1; }
  [ "${code}" = "204" ] || [ "${code}" = "200" ] \
    || { echo "❌ RESET: delete_series HTTP ${code} em ${url} (admin API desligada? match inválido?)" >&2; exit 1; }
  curl -s --max-time 30 -X POST "${url}/api/v1/admin/tsdb/clean_tombstones" >/dev/null || true
done

# 4) Mongo: dropa a coleção de histórico (container fica de pé)
mid="$(docker ps -q -f name=mongo)"
[ -n "${mid}" ] || { echo "❌ RESET: container mongo não está de pé" >&2; exit 1; }
log "drop ${MONGO_DB}.${MONGO_COLL}"
docker exec "${mid}" mongosh --quiet "${MONGO_DB}" --eval "db.${MONGO_COLL}.drop()" >/dev/null

# 5) App: recria os 4 containers com o SIM_CONFIG_SRC da réplica (mongo NÃO é recriado)
log "force-recreate app containers com SIM_CONFIG_SRC=${CONFIG_PATH}"
export SIM_CONFIG_SRC="${CONFIG_PATH}"
docker compose -f "${ROOT_DIR}/compose.yaml" \
  up -d --force-recreate --no-deps ai-engine actuator broker monitor

log "reset concluído"
