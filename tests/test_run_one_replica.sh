#!/usr/bin/env bash
# Teste offline do run_one_replica.sh: modo --dry (sem docker/make) e guarda do RESET_MODE=light.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${HERE}/../run_one_replica.sh"
fail=0

# 1) --dry escreve provenance sem rodar docker
tmp="$(mktemp -d)"
mkdir -p "${HERE}/../ai-engine/prompts/workshop"
echo "CAND" > "${HERE}/../ai-engine/prompts/workshop/cand_test.txt"
if bash "${SCRIPT}" --dry "workshop/cand_test" "${HERE}/../simulator/data/config_compressed.yaml" "${tmp}"; then
  [ -f "${tmp}/provenance.json" ] || { echo "FAIL: provenance ausente"; fail=1; }
else
  echo "FAIL: --dry retornou erro"; fail=1
fi

# 2) RESET_MODE=light aborta com 'não validado'
out="$(RESET_MODE=light bash "${SCRIPT}" --dry "workshop/cand_test" "${HERE}/../simulator/data/config_compressed.yaml" "${tmp}" 2>&1)"
echo "${out}" | grep -qi "não validado" || { echo "FAIL: light não abortou"; fail=1; }

rm -rf "${tmp}" "${HERE}/../ai-engine/prompts/workshop/cand_test.txt"
[ "${fail}" -eq 0 ] && echo "OK" || exit 1
