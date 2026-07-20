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

log() { echo "[reset $(date -u +%H:%M:%S)] $*"; }

# Mongo db/collection: lidos do config, nunca hardcoded (a app lê de lá — ver
# ai-engine/engine/recommendation_history_db.py). Se o config mudar os nomes, o
# reset tem que dropar a coleção certa.
MONGO_DB="$(yq '.["ai-engine"].recommendation_history.mongodb.database' "${CONFIG_PATH}")"
MONGO_COLL="$(yq '.["ai-engine"].recommendation_history.mongodb.collection' "${CONFIG_PATH}")"
[ -n "${MONGO_DB}" ] && [ "${MONGO_DB}" != "null" ] || { echo "❌ RESET: mongodb.database vazio/null no config" >&2; exit 1; }
[ -n "${MONGO_COLL}" ] && [ "${MONGO_COLL}" != "null" ] || { echo "❌ RESET: mongodb.collection vazio/null no config" >&2; exit 1; }
MONITOR_DB="${MONITOR_DB:-monitor}"; MONITOR_COLL="${MONITOR_COLL:-metrics}"

export KUBECONFIG="${MEMBERS_KUBECONFIG}"

# 1a) Karmada CP primeiro: é ONDE o workload é criado (broker usa karmada.config).
#     Apagar aqui faz o Karmada despropagar dos members; o sweep abaixo pega restos.
KARMADA_KUBECONFIG="${KARMADA_KUBECONFIG:-$HOME/.kube/karmada.config}"
log "workload delete no control plane do Karmada (default)"
KUBECONFIG="${KARMADA_KUBECONFIG}" kubectl --context karmada-apiserver -n default \
  delete deployments,jobs --all --ignore-not-found --wait=true --timeout=180s

# 1b) Workload: apaga todo deploy/job/pod de workload (namespace default) nos dois members
for ctx in member1 member2; do
  log "workload delete em ${ctx}/default"
  kubectl --context "${ctx}" -n default delete deployments,jobs,pods --all \
    --ignore-not-found --wait=true --timeout=120s
done

# 2) Nós: apaga TODOS os nós não-control-plane (limpa os que o autoscaler somou —
#    esses só têm cloud=public + kwok.x-k8s.io/node=fake, NÃO type=kwok) e re-aplica o baseline
for ctx in member1 member2; do
  log "nós (não control-plane) delete em ${ctx}"
  kubectl --context "${ctx}" delete nodes -l '!node-role.kubernetes.io/control-plane' \
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

# 4b) Métricas do monitor: o `full` destrói o volume do mongo (compose down -v); o `light`
#     precisa dropar explicitamente. Sem isso o histórico da réplica anterior fica na coleção
#     e o primeiro ciclo (janela 180s > duração do reset) analisa dado da réplica passada.
log "drop ${MONITOR_DB}.${MONITOR_COLL}"
docker exec "${mid}" mongosh --quiet "${MONITOR_DB}" --eval "db.${MONITOR_COLL}.drop()" >/dev/null

# 5) App: recria os 4 containers com o SIM_CONFIG_SRC da réplica (mongo NÃO é recriado)
log "force-recreate app containers com SIM_CONFIG_SRC=${CONFIG_PATH}"
export SIM_CONFIG_SRC="${CONFIG_PATH}"
docker compose -f "${ROOT_DIR}/compose.yaml" \
  up -d --force-recreate --no-deps ai-engine actuator broker monitor

log "reset concluído"
