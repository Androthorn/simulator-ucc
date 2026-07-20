#!/usr/bin/env bash
# assert_clean_state.sh — guardrail do RESET_MODE=light. Roda APÓS o reset e ANTES
# do sim em TODA réplica light. Prova que o estado inicial é idêntico ao do `full`.
# Qualquer violação → morre alto (exit !=0). Nenhum vazamento silencioso.
# Uso: assert_clean_state.sh <config_path>
#      assert_clean_state.sh --print-expected <config_path>   # offline, só imprime nós esperados
set -uo pipefail

MEMBERS_KUBECONFIG="${MEMBERS_KUBECONFIG:-$HOME/.kube/members.config}"
PROM_ENDPOINTS=("${PROM_MEMBER1:-http://localhost:9090}" "${PROM_MEMBER2:-http://localhost:9091}")
MONGO_DB="ai_engine"; MONGO_COLL="recommendation_history"
APP_CONTAINERS=(ai-engine actuator broker monitor)

die() { echo "❌ ASSERT: $*" >&2; exit 1; }

PRINT_ONLY=0; [ "${1:-}" = "--print-expected" ] && { PRINT_ONLY=1; shift; }
CONFIG_PATH="${1:?config_path}"
[ -f "${CONFIG_PATH}" ] || die "config não existe: ${CONFIG_PATH}"

# Fonte da verdade dos nós = a mesma do create_kwok_nodes.sh (load_config.sh)
MEMBER1_NODES="$(yq '.clusters.member1.nodes' "${CONFIG_PATH}")"
MEMBER2_NODES="$(yq '.clusters.member2.nodes' "${CONFIG_PATH}")"
[[ "${MEMBER1_NODES}" =~ ^[0-9]+$ ]] || die "member1.nodes inválido: '${MEMBER1_NODES}'"
[[ "${MEMBER2_NODES}" =~ ^[0-9]+$ ]] || die "member2.nodes inválido: '${MEMBER2_NODES}'"

if [ "${PRINT_ONLY}" -eq 1 ]; then
  echo "member1=${MEMBER1_NODES} member2=${MEMBER2_NODES}"; exit 0
fi

# Daqui pra baixo tudo toca o cluster. O kubeconfig real vive em /root/.kube (o setup roda
# como root e `sudo -E` é ignorado nesta máquina) → este trecho EXIGE root.
[ "$(id -u)" -eq 0 ] || die "precisa rodar como root (sudo) — o kubeconfig do cluster está em /root/.kube"

export KUBECONFIG="${MEMBERS_KUBECONFIG}"

# 1) nós KWOK == baseline do config (pega nós que o autoscaler somou)
n1_out="$(kubectl --context member1 get nodes -l type=kwok -o name 2>/dev/null)" \
  || die "kubectl get nodes (member1) falhou — cluster inacessível?"
n1="$(printf '%s' "$n1_out" | grep -c . || true)"
n2_out="$(kubectl --context member2 get nodes -l type=kwok -o name 2>/dev/null)" \
  || die "kubectl get nodes (member2) falhou — cluster inacessível?"
n2="$(printf '%s' "$n2_out" | grep -c . || true)"
[ "${n1}" -eq "${MEMBER1_NODES}" ] || die "member1 tem ${n1} nós KWOK, esperado ${MEMBER1_NODES}"
[ "${n2}" -eq "${MEMBER2_NODES}" ] || die "member2 tem ${n2} nós KWOK, esperado ${MEMBER2_NODES}"

# 2) zero workload (deploy/pod) no namespace default nos dois members
for ctx in member1 member2; do
  d="$(kubectl --context "${ctx}" -n default get deployments -o name 2>/dev/null)" \
    || die "${ctx}: kubectl get deployments falhou — cluster inacessível?"
  p="$(kubectl --context "${ctx}" -n default get pods -o name 2>/dev/null)" \
    || die "${ctx}: kubectl get pods falhou — cluster inacessível?"
  dn="$(printf '%s' "$d" | grep -c . || true)"
  pn="$(printf '%s' "$p" | grep -c . || true)"
  [ "${dn}" -eq 0 ] || die "${ctx}: ${dn} deployment(s) de workload em default (esperado 0)"
  [ "${pn}" -eq 0 ] || die "${ctx}: ${pn} pod(s) de workload em default (esperado 0)"
done

# 3) Prometheus sem séries de workload do run anterior (mesma série que o sim lê)
probe='count(count_over_time(kube_pod_status_phase{namespace="default"}[6h]))'
for url in "${PROM_ENDPOINTS[@]}"; do
  resp="$(curl -s --max-time 15 -w $'\n%{http_code}' --data-urlencode "query=${probe}" "${url}/api/v1/query")" \
    || die "Prometheus ${url}: curl falhou — inacessível?"
  code="$(printf '%s' "$resp" | tail -n1)"
  body="$(printf '%s' "$resp" | sed '$d')"
  [ "${code}" = "200" ] || die "Prometheus ${url}: HTTP ${code} (esperado 200)"
  status="$(printf '%s' "$body" | jq -r '.status' 2>/dev/null)"
  [ "${status}" = "success" ] || die "Prometheus ${url}: status='${status}' (esperado success)"
  len="$(printf '%s' "$body" | jq -r '.data.result | length' 2>/dev/null)"
  [ "${len}" = "0" ] || die "Prometheus ${url}: sonda de workload retornou '${len}' série(s) (esperado 0 — vazamento)"
done

# 4) recommendation_history == 0 docs
mid="$(docker ps -q -f name=mongo)"
[ -n "${mid}" ] || die "container mongo não está de pé"
cnt="$(docker exec "${mid}" mongosh --quiet "${MONGO_DB}" --eval "db.${MONGO_COLL}.countDocuments({})" 2>/dev/null)" \
  || die "mongosh countDocuments falhou"
cnt="$(printf '%s' "$cnt" | tr -d '[:space:]')"
[ "${cnt}" = "0" ] || die "recommendation_history tem '${cnt}' doc(s) (esperado 0)"

# 5) app containers todos running
for c in "${APP_CONTAINERS[@]}"; do
  status="$(docker inspect -f '{{.State.Status}}' "${c}" 2>/dev/null || echo missing)"
  [ "${status}" = "running" ] || die "container ${c} não está running (status=${status})"
done

echo "✅ state-assertion OK: nós ${n1}/${n2}, zero workload, Prometheus limpo, mongo 0, app up"
