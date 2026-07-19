#!/usr/bin/env bash
# Integração do RESET_MODE=light — REQUER cluster de pé (rode 1 réplica full antes).
# Prova o par reset/assert: suja o estado → assert FALHA; reset → assert PASSA.
# Uso: bash tests/test_light_reset_integration.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${HERE}/.."
CFG="${ROOT}/simulator/data/config_compressed.yaml"
export KUBECONFIG="${HOME}/.kube/members.config"
fail=0

# Guard: cluster de pé?
sudo docker ps --format '{{.Names}}' | grep -qx member1-control-plane \
  || { echo "SKIP: nenhum cluster de pé (rode uma réplica full primeiro)"; exit 0; }

# 1) suja o estado: adiciona um nó KWOK a mais no member1
kubectl --context member1 apply -f - >/dev/null <<'EOF'
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
