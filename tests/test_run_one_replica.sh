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

# 2) RESET_MODE=light --dry é válido e grava provenance com reset_mode: light
if RESET_MODE=light bash "${SCRIPT}" --dry "workshop/cand_test" "${HERE}/../simulator/data/config_compressed.yaml" "${tmp}" >/dev/null 2>&1; then
  grep -q '"reset_mode": *"light"' "${tmp}/provenance.json" || { echo "FAIL: provenance light ausente/errado"; fail=1; }
else
  echo "FAIL: light --dry retornou erro"; fail=1
fi

# 3) RESET_MODE inválido morre alto
RESET_MODE=bogus bash "${SCRIPT}" --dry "workshop/cand_test" "${HERE}/../simulator/data/config_compressed.yaml" "${tmp}" >/dev/null 2>&1 \
  && { echo "FAIL: RESET_MODE inválido não abortou"; fail=1; }

rm -rf "${tmp}" "${HERE}/../ai-engine/prompts/workshop/cand_test.txt"
[ "${fail}" -eq 0 ] && echo "OK" || exit 1
