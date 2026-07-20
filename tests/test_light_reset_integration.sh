#!/usr/bin/env bash
# Integração do RESET_MODE=light — REQUER cluster de pé (rode 1 réplica full antes).
# Prova o par reset/assert: suja o estado → assert FALHA; reset → assert PASSA.
# Uso: sudo bash tests/test_light_reset_integration.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${HERE}/.."
CFG="${ROOT}/simulator/data/config_compressed.yaml"
export KUBECONFIG="${HOME}/.kube/members.config"
fail=0

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

# 1) suja o estado: adiciona um nó KWOK a mais no member1
if ! kubectl --context member1 apply -f - >/dev/null <<'EOF'
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
then
  echo "❌ ABORT: não consegui sujar o estado (kubectl apply falhou)"; exit 1
fi
kubectl --context member1 get node member1-node-dirty >/dev/null 2>&1 \
  || { echo "❌ ABORT: nó sujo não aparece após apply — estado não foi sujado, teste inválido"; exit 1; }

# 2) assert DEVE falhar (nó a mais)
if bash "${ROOT}/scripts/assert_clean_state.sh" "${CFG}" >/dev/null 2>&1; then
  echo "FAIL: assert passou com estado sujo"; fail=1
else
  echo "ok: assert pegou o estado sujo"
fi

# 3) reset DEVE limpar
bash "${ROOT}/scripts/light_reset.sh" "${CFG}" >/dev/null 2>&1 || { echo "FAIL: light_reset erro"; fail=1; }

# 4) assert DEVE passar após reset
if bash "${ROOT}/scripts/assert_clean_state.sh" "${CFG}"; then
  echo "ok: assert passou após reset"
else
  echo "FAIL: assert reprovou após reset"; fail=1
fi

[ "${fail}" -eq 0 ] && echo "OK" || exit 1
