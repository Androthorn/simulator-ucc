#!/usr/bin/env bash

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${ROOT_DIR}/simulator/data/config.yaml"
BACKUP_FILE="${CONFIG_FILE}.auto_backup"

if ! command -v yq >/dev/null 2>&1; then
  echo "Error: 'yq' not found in PATH. Please install yq (v4+) before running this script."
  exit 1
fi

if [ ! -f "${CONFIG_FILE}" ]; then
  echo "Error: configuration file not found at: ${CONFIG_FILE}"
  exit 1
fi

# Help / usage
if [ "${1-}" = "-h" ] || [ "${1-}" = "--help" ]; then
  script_name="$(basename "$0")"
  cat <<EOF
Usage: ${script_name} [INPUT_FILTER] [GRAPH_VERSION]

INPUT_FILTER:
  (none)       Run both input_const.json and input_varia.json
  const        Run only input_const.json (24 nodes/cluster)
  varia        Run only input_varia.json (38 nodes/cluster)

GRAPH_VERSION:
  (none)       Run both v1 and v2
  v1           Use only graph version v1
  v2           Use only graph version v2

Examples:
  ${script_name}               # all inputs, v1 and v2
  ${script_name} const         # only input_const.json, v1 and v2
  ${script_name} varia v1      # only input_varia.json, graph v1
  ${script_name} "" v2         # both inputs, only graph v2
EOF
  exit 0
fi

echo "Checking sudo credentials (you may be prompted once)..."
if ! sudo -v; then
  echo "Error: failed to obtain sudo credentials."
  exit 1
fi

# Keep sudo credentials alive while the script runs
(
  while true; do
    sudo -n true >/dev/null 2>&1 || exit 0
    sleep 60
  done
) &
SUDO_KEEPALIVE_PID=$!

cleanup() {
  if [ -n "${SUDO_KEEPALIVE_PID:-}" ]; then
    kill "${SUDO_KEEPALIVE_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "Creating configuration backup at: ${BACKUP_FILE}"
cp "${CONFIG_FILE}" "${BACKUP_FILE}"

# Parameter combinations
MODELS=("anthropic/claude-sonnet-4.5")
INPUTS=("input_const.json" "input_varia.json")
TEMPERATURES=(0.1 0.5)
GRAPH_VERSIONS=("v1" "v2")

# Optional CLI filters:
#   ./run_simulations.sh                 # runs all combinations (both inputs, v1+v2)
#   ./run_simulations.sh const           # only input_const.json (both v1+v2)
#   ./run_simulations.sh varia           # only input_varia.json (both v1+v2)
#   ./run_simulations.sh const v1        # only input_const.json + graph v1
#   ./run_simulations.sh varia v2        # only input_varia.json + graph v2
INPUT_FILTER="${1-}"
GRAPH_FILTER="${2-}"

# Filter by input type (const/varia)
case "${INPUT_FILTER}" in
  "" )
    # No filter: keep both inputs
    ;;
  const)
    INPUTS=("input_const.json")
    ;;
  varia)
    INPUTS=("input_varia.json")
    ;;
  *)
    echo "Invalid input type: '${INPUT_FILTER}'"
    echo "Usage: $0 [const|varia] [v1|v2]"
    exit 1
    ;;
esac

# Optional filter by graph version
case "${GRAPH_FILTER}" in
  "" )
    # No filter: keep both versions
    ;;
  v1)
    GRAPH_VERSIONS=("v1")
    ;;
  v2)
    GRAPH_VERSIONS=("v2")
    ;;
  *)
    echo "Invalid graph_version: '${GRAPH_FILTER}'. Use 'v1' or 'v2'."
    exit 1
    ;;
esac

run_counter=0
declare -a RUN_STATUS
declare -a RUN_DESC

for model in "${MODELS[@]}"; do
  for input_file in "${INPUTS[@]}"; do
    for temp in "${TEMPERATURES[@]}"; do
      for graph in "${GRAPH_VERSIONS[@]}"; do
        run_counter=$((run_counter + 1))
        echo "============================================"
        echo "Simulation ${run_counter}:"
        echo "  model           = ${model}"
        echo "  input_json      = ${input_file}"
        echo "  temperature     = ${temp}"
        echo "  graph_version   = ${graph}"
        echo "============================================"

        # Restore original config before applying changes
        cp "${BACKUP_FILE}" "${CONFIG_FILE}"

        # Update AI engine parameters in config.yaml
        yq -i '.["ai-engine"].ai.selected_model = "'"${model}"'"' "${CONFIG_FILE}"
        yq -i '.["ai-engine"].data.input_json = "'"${input_file}"'"' "${CONFIG_FILE}"
        yq -i '.["ai-engine"].ai.multi_agent.graph_version = "'"${graph}"'"' "${CONFIG_FILE}"
        yq -i '.["ai-engine"].ai.multi_agent.generation_config.temperature = '"${temp}" "${CONFIG_FILE}"

        # Adjust cluster size (nodes per member) based on the selected input file
        # - input_const.json  -> 24 nodes per cluster
        # - input_varia.json  -> 38 nodes per cluster
        nodes_value=38
        case "${input_file}" in
          input_const.json)
            nodes_value=24
            ;;
          input_varia.json)
            nodes_value=38
            ;;
        esac
        yq -i ".clusters.member1.nodes = ${nodes_value}" "${CONFIG_FILE}"
        yq -i ".clusters.member2.nodes = ${nodes_value}" "${CONFIG_FILE}"

        echo "Configuration applied to ${CONFIG_FILE}."

        # Ensure simulator uses the same input file as configured for the AI engine
        SIM_INPUT_SRC="${ROOT_DIR}/simulator/data/${input_file}"
        SIM_INPUT_DST="${ROOT_DIR}/simulator/data/input.json"
        if [ -f "${SIM_INPUT_SRC}" ]; then
          echo "Syncing simulator input: ${SIM_INPUT_SRC} -> ${SIM_INPUT_DST}"
          cp "${SIM_INPUT_SRC}" "${SIM_INPUT_DST}"
        else
          echo "Warning: simulator input source file not found: ${SIM_INPUT_SRC}"
        fi

        desc="Model=${model} | Input=${input_file} | Temp=${temp} | Graph=${graph}"
        status="SUCCESS"

        echo "Running: make setup-and-start (this may take a while)..."
        if ! (cd "${ROOT_DIR}" && sudo -E make setup-and-start); then
          echo "❌ Failed to execute make setup-and-start."
          status="FAILED (setup-and-start)"
        else
          echo "Finding latest output directory in simulator/data/output..."
          LAST_RUN_DIR="$(ls -1dt "${ROOT_DIR}/simulator/data/output"/*/ 2>/dev/null | head -1 || true)"
          if [ -z "${LAST_RUN_DIR}" ]; then
            echo "Warning: no output directory found in simulator/data/output. Skipping plot generation."
            status="FAILED (no output)"
          else
            TIMESTAMP="$(basename "${LAST_RUN_DIR}")"
            echo "Latest simulation detected: ${TIMESTAMP}"

            echo "Copying config and input used to ${LAST_RUN_DIR}..."
            if ! sudo cp "${CONFIG_FILE}" "${LAST_RUN_DIR%/}/config_used.yaml"; then
              echo "Warning: failed to copy config file to ${LAST_RUN_DIR}."
            fi
            if ! sudo cp "${ROOT_DIR}/simulator/data/${input_file}" "${LAST_RUN_DIR%/}/input_used.json"; then
              echo "Warning: failed to copy input file to ${LAST_RUN_DIR}."
            fi

            echo "Generating plots with analyzer for ${TIMESTAMP}..."
            if ! (cd "${ROOT_DIR}/analyzer" && make generate-plots "${TIMESTAMP}"); then
              echo "❌ Failed to generate plots with analyzer."
              status="FAILED (generate-plots)"
            fi

            # Rename simulator and analyzer output directories to model_input_version_temperature
            safe_model="${model//\//-}"
            safe_model="${safe_model// /_}"
            input_base="$(basename "${input_file}" .json)"
            new_name="${safe_model}_${input_base}_${graph}_${temp}"

            old_sim_dir="${LAST_RUN_DIR%/}"
            new_sim_dir="${ROOT_DIR}/simulator/data/output/${new_name}"

            echo "Renaming simulator output directory to: ${new_sim_dir}"
            if [ -d "${old_sim_dir}" ] && [ "${old_sim_dir}" != "${new_sim_dir}" ]; then
              if ! sudo mv "${old_sim_dir}" "${new_sim_dir}"; then
                echo "Warning: failed to rename simulator output directory from ${old_sim_dir} to ${new_sim_dir}."
              else
                LAST_RUN_DIR="${new_sim_dir}/"
              fi
            fi

            old_an_dir="${ROOT_DIR}/analyzer/output/${TIMESTAMP}"
            new_an_dir="${ROOT_DIR}/analyzer/output/${new_name}"
            echo "Renaming analyzer output directory to: ${new_an_dir}"
            if [ -d "${old_an_dir}" ] && [ "${old_an_dir}" != "${new_an_dir}" ]; then
              if ! sudo mv "${old_an_dir}" "${new_an_dir}"; then
                echo "Warning: failed to rename analyzer output directory from ${old_an_dir} to ${new_an_dir}."
              fi
            fi
          fi
        fi

        RUN_STATUS[run_counter]="${status}"
        RUN_DESC[run_counter]="${desc}"

        echo "Simulation ${run_counter} finished with status: ${status}."
        echo
      done
    done
  done
done

echo "Restoring original configuration at ${CONFIG_FILE}."
cp "${BACKUP_FILE}" "${CONFIG_FILE}"

echo "============================================"
echo "Simulations summary:"
echo "  Total: ${run_counter}"

success_count=0
fail_count=0
if [ "${run_counter}" -gt 0 ]; then
  for i in $(seq 1 "${run_counter}"); do
    if [[ "${RUN_STATUS[i]}" == "SUCCESS" ]]; then
      success_count=$((success_count + 1))
    else
      fail_count=$((fail_count + 1))
    fi
  done
fi

echo "  Success: ${success_count}"
echo "  Failed:  ${fail_count}"
echo "--------------------------------------------"
echo "Details:"
if [ "${run_counter}" -gt 0 ]; then
  for i in $(seq 1 "${run_counter}"); do
    echo "  ${i}. ${RUN_STATUS[i]} | ${RUN_DESC[i]}"
  done
else
  echo "  No simulations were executed."
fi
echo "============================================"

# Ensure output directories are owned by the invoking user (not root),
# so they can be edited or deleted without sudo.
OWNER_USER="${SUDO_USER:-$USER}"
if [ -n "${OWNER_USER}" ]; then
  echo "Fixing ownership of output directories for user: ${OWNER_USER}"
  if [ -d "${ROOT_DIR}/simulator/data/output" ]; then
    sudo chown -R "${OWNER_USER}:${OWNER_USER}" "${ROOT_DIR}/simulator/data/output" || true
  fi
  if [ -d "${ROOT_DIR}/analyzer/output" ]; then
    sudo chown -R "${OWNER_USER}:${OWNER_USER}" "${ROOT_DIR}/analyzer/output" || true
  fi
fi

echo "All simulations finished."
echo "You can find outputs in: ${ROOT_DIR}/simulator/data/output/"
