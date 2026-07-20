#!/usr/bin/env bash
# Integração do RESET_MODE=light — REQUER cluster de pé (rode 1 réplica full antes).
# Prova que a assertion DETECTA cada eixo sujo independentemente (nó estilo autoscaler
# sem type=kwok, doc no mongo, workload no control plane do Karmada, nó com type=kwok)
# e que o reset limpa todos eles. Leva alguns minutos (dois resets completos) e roda
# como root.
# Uso: sudo bash tests/test_light_reset_integration.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${HERE}/.."
CFG="${ROOT}/simulator/data/config_compressed.yaml"
export KUBECONFIG="${HOME}/.kube/members.config"
CFG_ABS="$(readlink -f "${CFG}")"
KARMADA_KUBECONFIG="${KARMADA_KUBECONFIG:-$HOME/.kube/karmada.config}"
MONGO_DB="$(yq '.["ai-engine"].recommendation_history.mongodb.database' "${CFG}")"
MONGO_COLL="$(yq '.["ai-engine"].recommendation_history.mongodb.collection' "${CFG}")"
fail=0

[ -n "${MONGO_DB}" ] && [ "${MONGO_DB}" != "null" ] \
  || { echo "❌ ABORT: MONGO_DB veio vazio/null de ${CFG} — não vou testar contra uma coleção errada"; exit 1; }
[ -n "${MONGO_COLL}" ] && [ "${MONGO_COLL}" != "null" ] \
  || { echo "❌ ABORT: MONGO_COLL veio vazio/null de ${CFG} — não vou testar contra uma coleção errada"; exit 1; }

assert_ok()   { bash "${ROOT}/scripts/assert_clean_state.sh" "${CFG}" >/dev/null 2>&1; }
reset_now()   { bash "${ROOT}/scripts/light_reset.sh" "${CFG}" >/dev/null 2>&1 \
                  || { echo "FAIL: light_reset erro"; fail=1; }; }
# Prova que a assertion DETECTA um eixo sujo. Se ela passar com o estado sujo,
# o guardrail está cego para esse eixo — exatamente o bug C1/C2.
expect_dirty_detected() { # $1 = descrição do eixo
  if assert_ok; then echo "FAIL: assert passou com estado sujo (${1}) — guardrail cego"; fail=1
  else echo "ok: assert detectou ${1}"; fi
}

[ "$(id -u)" -eq 0 ] || { echo "❌ ABORT: rode como root — sudo bash tests/test_light_reset_integration.sh (o kubeconfig do cluster está em /root/.kube)"; exit 1; }

# Guard 1: os 3 control-planes de pé? (senão nada a testar → SKIP limpo)
names="$(docker ps --format '{{.Names}}')"
for c in member1-control-plane member2-control-plane karmada-host-control-plane; do
  echo "${names}" | grep -qx "${c}" \
    || { echo "SKIP: cluster incompleto (${c} não está de pé); rode 'make setup' primeiro"; exit 0; }
done

# Guard 2: kubectl realmente alcança o cluster? Se os containers estão de pé mas o
# kubectl não autentica (kubeconfig stale vs cluster recriado), este teste não consegue
# distinguir "sujo" de "inacessível" — aborta ALTO em vez de dar falso-verde.
kubectl --context member1 get nodes >/dev/null 2>&1 \
  || { echo "❌ ABORT: containers de pé mas kubectl não alcança o cluster (kubeconfig stale? cluster recriado?). Rode 'make setup' pra re-semear um kubeconfig coerente."; exit 1; }

# ---- Phase A: baseline ----
reset_now
if assert_ok; then
  echo "ok: baseline limpo após reset"
else
  echo "FAIL: assert reprovou no baseline"; fail=1
fi

# ---- Phase B: detecção, um eixo por vez ----

# B1 — nó SEM type: kwok (prova do C1; mimetiza os labels do próprio template do autoscaler)
kubectl --context member2 apply -f - >/dev/null <<'EOF' || { echo "FAIL: não sujei (nó autoscaler-like)"; fail=1; }
apiVersion: v1
kind: Node
metadata:
  annotations:
    kwok.x-k8s.io/node: fake
  labels:
    cloud: public
    kwok.x-k8s.io/node: fake
  name: member2-node-autoscaled-probe
status:
  allocatable: {cpu: "8", memory: 16Gi, pods: 110}
  capacity: {cpu: "8", memory: 16Gi, pods: 110}
  phase: Running
EOF
expect_dirty_detected "nó do autoscaler (sem type=kwok)"
kubectl --context member2 delete node member2-node-autoscaled-probe --ignore-not-found >/dev/null 2>&1

# B2 — documento na coleção de histórico
mid="$(docker ps -q -f name=^mongo$)"
docker exec "${mid}" mongosh --quiet "${MONGO_DB}" --eval "db.${MONGO_COLL}.insertOne({probe:1})" >/dev/null
expect_dirty_detected "doc em ${MONGO_DB}.${MONGO_COLL}"
docker exec "${mid}" mongosh --quiet "${MONGO_DB}" --eval "db.${MONGO_COLL}.deleteMany({})" >/dev/null

# B3 — workload no control plane do Karmada (prova do C2)
KUBECONFIG="${KARMADA_KUBECONFIG}" kubectl --context karmada-apiserver -n default apply -f - >/dev/null <<'EOF' || { echo "FAIL: não sujei (deployment no karmada CP)"; fail=1; }
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dirty-leak-probe
  namespace: default
spec:
  replicas: 1
  selector: {matchLabels: {app: dirty-leak-probe}}
  template:
    metadata:
      labels: {app: dirty-leak-probe, cloud: private}
    spec:
      containers:
        - name: c
          image: registry.k8s.io/pause:3.10
EOF
expect_dirty_detected "deployment no control plane do Karmada"
KUBECONFIG="${KARMADA_KUBECONFIG}" kubectl --context karmada-apiserver -n default \
  delete deployment dirty-leak-probe --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1

# B4 — eixo original, nó COM type: kwok no member1
kubectl --context member1 apply -f - >/dev/null <<'EOF' || { echo "FAIL: não sujei (nó extra com type=kwok)"; fail=1; }
apiVersion: v1
kind: Node
metadata:
  labels: {type: kwok, cloud: private}
  name: member1-node-dirty
status:
  allocatable: {cpu: "8", memory: 16Gi, pods: 110}
  capacity: {cpu: "8", memory: 16Gi, pods: 110}
  phase: Running
EOF
expect_dirty_detected "nó extra com type=kwok"
kubectl --context member1 delete node member1-node-dirty --ignore-not-found >/dev/null 2>&1

# ---- Phase C: o reset realmente limpa tudo ----

kubectl --context member2 apply -f - >/dev/null <<'EOF' || { echo "FAIL: não sujei (nó autoscaler-like, fase C)"; fail=1; }
apiVersion: v1
kind: Node
metadata:
  annotations:
    kwok.x-k8s.io/node: fake
  labels:
    cloud: public
    kwok.x-k8s.io/node: fake
  name: member2-node-autoscaled-probe
status:
  allocatable: {cpu: "8", memory: 16Gi, pods: 110}
  capacity: {cpu: "8", memory: 16Gi, pods: 110}
  phase: Running
EOF

docker exec "${mid}" mongosh --quiet "${MONGO_DB}" --eval "db.${MONGO_COLL}.insertOne({probe:1})" >/dev/null

KUBECONFIG="${KARMADA_KUBECONFIG}" kubectl --context karmada-apiserver -n default apply -f - >/dev/null <<'EOF' || { echo "FAIL: não sujei (deployment no karmada CP, fase C)"; fail=1; }
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dirty-leak-probe
  namespace: default
spec:
  replicas: 1
  selector: {matchLabels: {app: dirty-leak-probe}}
  template:
    metadata:
      labels: {app: dirty-leak-probe, cloud: private}
    spec:
      containers:
        - name: c
          image: registry.k8s.io/pause:3.10
EOF

kubectl --context member1 apply -f - >/dev/null <<'EOF' || { echo "FAIL: não sujei (nó extra com type=kwok, fase C)"; fail=1; }
apiVersion: v1
kind: Node
metadata:
  labels: {type: kwok, cloud: private}
  name: member1-node-dirty
status:
  allocatable: {cpu: "8", memory: 16Gi, pods: 110}
  capacity: {cpu: "8", memory: 16Gi, pods: 110}
  phase: Running
EOF

reset_now

if assert_ok; then
  echo "ok: assert passou após reset (todos os eixos)"
else
  echo "FAIL: assert reprovou após reset"; fail=1
fi

# containers montaram o config DESTA réplica (não o config.yaml congelado)?
# Regressão do bug em que SIM_CONFIG_SRC era descartado pelo env_reset do sudo.
cfg_ok=1
for c in ai-engine monitor; do
  got="$(docker inspect "${c}" --format '{{range .Mounts}}{{if eq .Destination "/app/simulator_config.yaml"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)"
  [ "${got}" = "${CFG_ABS}" ] \
    || { echo "FAIL: ${c} montou '${got}', esperado '${CFG_ABS}' (SIM_CONFIG_SRC não chegou ao compose)"; cfg_ok=0; fail=1; }
done
got="$(docker inspect actuator --format '{{range .Mounts}}{{if eq .Destination "/simulator/data/config.yaml"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)"
[ "${got}" = "${CFG_ABS}" ] \
  || { echo "FAIL: actuator montou '${got}', esperado '${CFG_ABS}' (SIM_CONFIG_SRC não chegou ao compose)"; cfg_ok=0; fail=1; }
[ "${cfg_ok}" -eq 1 ] && echo "ok: containers montaram o config da réplica"

[ "${fail}" -eq 0 ] && echo "OK" || exit 1
