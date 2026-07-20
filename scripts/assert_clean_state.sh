#!/usr/bin/env bash
# assert_clean_state.sh — guardrail do RESET_MODE=light. Roda APÓS o reset e ANTES
# do sim em TODA réplica light. Prova que o estado inicial é idêntico ao do `full`.
# Qualquer violação → morre alto (exit !=0). Nenhum vazamento silencioso.
# Uso: assert_clean_state.sh <config_path>
#      assert_clean_state.sh --print-expected <config_path>   # offline, só imprime nós esperados
set -uo pipefail

MEMBERS_KUBECONFIG="${MEMBERS_KUBECONFIG:-$HOME/.kube/members.config}"
PROM_ENDPOINTS=("${PROM_MEMBER1:-http://localhost:9090}" "${PROM_MEMBER2:-http://localhost:9091}")
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

# Mongo db/collection: lidos do config, nunca hardcoded (mesmo princípio dos nós —
# a app lê de lá, ver ai-engine/engine/recommendation_history_db.py).
MONGO_DB="$(yq '.["ai-engine"].recommendation_history.mongodb.database' "${CONFIG_PATH}")"
MONGO_COLL="$(yq '.["ai-engine"].recommendation_history.mongodb.collection' "${CONFIG_PATH}")"
[ -n "${MONGO_DB}" ] && [ "${MONGO_DB}" != "null" ] || die "mongodb.database vazio/null no config"
[ -n "${MONGO_COLL}" ] && [ "${MONGO_COLL}" != "null" ] || die "mongodb.collection vazio/null no config"
MONITOR_DB="${MONITOR_DB:-monitor}"; MONITOR_COLL="${MONITOR_COLL:-metrics}"
MONITOR_MAX_AGE_S="${MONITOR_MAX_AGE_S:-600}"

export KUBECONFIG="${MEMBERS_KUBECONFIG}"

# 1) nós == baseline do config, contando TODOS os não-control-plane (pega nós que o
#    autoscaler somou — esses só têm cloud=public + kwok.x-k8s.io/node=fake, NÃO type=kwok)
n1_out="$(kubectl --context member1 get nodes -l '!node-role.kubernetes.io/control-plane' -o name 2>/dev/null)" \
  || die "kubectl get nodes (member1) falhou — cluster inacessível?"
n1="$(printf '%s' "$n1_out" | grep -c . || true)"
n2_out="$(kubectl --context member2 get nodes -l '!node-role.kubernetes.io/control-plane' -o name 2>/dev/null)" \
  || die "kubectl get nodes (member2) falhou — cluster inacessível?"
n2="$(printf '%s' "$n2_out" | grep -c . || true)"
[ "${n1}" -eq "${MEMBER1_NODES}" ] || die "member1 tem ${n1} nós, esperado ${MEMBER1_NODES}"
[ "${n2}" -eq "${MEMBER2_NODES}" ] || die "member2 tem ${n2} nós, esperado ${MEMBER2_NODES}"

# 1b) Karmada CP: é onde o workload nasce; restos aqui re-propagam pros members.
KARMADA_KUBECONFIG="${KARMADA_KUBECONFIG:-$HOME/.kube/karmada.config}"
kd_out="$(KUBECONFIG="${KARMADA_KUBECONFIG}" kubectl --context karmada-apiserver -n default \
  get deployments,jobs -o name 2>/dev/null)" \
  || die "kubectl get deployments,jobs no karmada-apiserver falhou — CP inacessível?"
kd="$(printf '%s' "${kd_out}" | grep -c . || true)"
[ "${kd}" -eq 0 ] || die "karmada CP tem ${kd} workload(s) em default (esperado 0 — re-propagaria pros members)"

# 2) zero workload (deploy/job/pod) no namespace default nos dois members
for ctx in member1 member2; do
  d="$(kubectl --context "${ctx}" -n default get deployments -o name 2>/dev/null)" \
    || die "${ctx}: kubectl get deployments falhou — cluster inacessível?"
  j="$(kubectl --context "${ctx}" -n default get jobs -o name 2>/dev/null)" \
    || die "${ctx}: kubectl get jobs falhou — cluster inacessível?"
  p="$(kubectl --context "${ctx}" -n default get pods -o name 2>/dev/null)" \
    || die "${ctx}: kubectl get pods falhou — cluster inacessível?"
  dn="$(printf '%s' "$d" | grep -c . || true)"
  jn="$(printf '%s' "$j" | grep -c . || true)"
  pn="$(printf '%s' "$p" | grep -c . || true)"
  [ "${dn}" -eq 0 ] || die "${ctx}: ${dn} deployment(s) de workload em default (esperado 0)"
  [ "${jn}" -eq 0 ] || die "${ctx}: ${jn} job(s) de workload em default (esperado 0)"
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

# 4b) monitor.metrics: não dá pra exigir 0 docs (o monitor repopula em ~5s após o reset).
#     Exigimos que NADA seja antigo: se o drop falhou, o run anterior inteiro (~12 min) sobrevive.
velhos="$(docker exec "${mid}" mongosh --quiet "${MONITOR_DB}" --eval "
  var lim = new Date(Date.now() - ${MONITOR_MAX_AGE_S}*1000).toISOString().slice(0,19).replace('T',' ');
  print(db.${MONITOR_COLL}.countDocuments({timestamp: {\$lt: lim}}));
" 2>/dev/null | tr -d '[:space:]')" \
  || die "mongosh countDocuments em ${MONITOR_DB}.${MONITOR_COLL} falhou"
[ "${velhos}" = "0" ] \
  || die "${MONITOR_DB}.${MONITOR_COLL} tem ${velhos} doc(s) mais velhos que ${MONITOR_MAX_AGE_S}s — histórico da réplica anterior sobreviveu ao reset"

# 5) app containers todos running
for c in "${APP_CONTAINERS[@]}"; do
  status="$(docker inspect -f '{{.State.Status}}' "${c}" 2>/dev/null || echo missing)"
  [ "${status}" = "running" ] || die "container ${c} não está running (status=${status})"
done

# 6) app containers montaram o config CERTO (não o config.yaml congelado default —
#    o bug do SIM_CONFIG_SRC dropado pelo sudo produzia containers "running" rodando
#    o prompt errado e gerando dados válidos-mas-errados)
CONFIG_ABS="$(readlink -f "${CONFIG_PATH}")"
for c in ai-engine monitor; do
  src="$(docker inspect "${c}" --format '{{range .Mounts}}{{if eq .Destination "/app/simulator_config.yaml"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)" \
    || die "docker inspect ${c} falhou"
  [ "${src}" = "${CONFIG_ABS}" ] || die "${c} montou config '${src}', esperado '${CONFIG_ABS}' (SIM_CONFIG_SRC não chegou)"
done
src="$(docker inspect actuator --format '{{range .Mounts}}{{if eq .Destination "/simulator/data/config.yaml"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)" \
  || die "docker inspect actuator falhou"
[ "${src}" = "${CONFIG_ABS}" ] || die "actuator montou config '${src}', esperado '${CONFIG_ABS}'"

echo "✅ state-assertion OK: nós ${n1}/${n2}, zero workload (members+karmada CP), Prometheus limpo, mongo 0, monitor.metrics sem doc >${MONITOR_MAX_AGE_S}s, app up com config correto"
