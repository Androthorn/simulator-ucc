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
Usage: ${script_name} [OPTIONS]

Runs the same simulation experiment multiple times with identical parameters.

OPTIONS:
  -n, --num-runs NUM        Number of times to run the experiment (default: 3)
  -i, --input INPUT         Input file: 'const' (input_const.json) or 'varia' (input_varia.json) (default: const)
  -g, --graph GRAPH         Graph version: 'v1' or 'v2' (default: v1)
  -t, --temperature TEMP    Temperature value (default: 0.1)
  -m, --model MODEL         Model name (default: anthropic/claude-haiku-4.5)
  -h, --help                Show this help message

Examples:
  ${script_name}                                    # Run 3 times with default settings
  ${script_name} -n 5                               # Run 5 times with default settings
  ${script_name} -n 10 -i varia -g v2 -t 0.5        # Run 10 times with custom settings
  ${script_name} --num-runs 5 --input const --graph v1 --temperature 0.1
EOF
  exit 0
fi

# Default values
NUM_RUNS=10
INPUT_TYPE="const"
GRAPH_VERSION="v2"
TEMPERATURE=0.1
MODEL="google/gemini-2.5-flash"

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--num-runs)
      NUM_RUNS="$2"
      shift 2
      ;;
    -i|--input)
      INPUT_TYPE="$2"
      shift 2
      ;;
    -g|--graph)
      GRAPH_VERSION="$2"
      shift 2
      ;;
    -t|--temperature)
      TEMPERATURE="$2"
      shift 2
      ;;
    -m|--model)
      MODEL="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      echo "Use -h or --help for usage information."
      exit 1
      ;;
  esac
done

# Validate number of runs
if ! [[ "${NUM_RUNS}" =~ ^[0-9]+$ ]] || [ "${NUM_RUNS}" -lt 1 ]; then
  echo "Error: number of runs must be a positive integer."
  exit 1
fi

# Validate and set input file
case "${INPUT_TYPE}" in
  const)
    INPUT_FILE="input_const.json"
    NODES_VALUE=10
    CPU_VALUE="8"
    MEMORY_VALUE="16Gi"
    ;;
  varia)
    INPUT_FILE="input_varia.json"
    NODES_VALUE=38
    CPU_VALUE="8"
    MEMORY_VALUE="16Gi"
    ;;
  *)
    echo "Error: invalid input type '${INPUT_TYPE}'. Use 'const' or 'varia'."
    exit 1
    ;;
esac

# Validate graph version
case "${GRAPH_VERSION}" in
  v1|v2)
    ;;
  *)
    echo "Error: invalid graph version '${GRAPH_VERSION}'. Use 'v1' or 'v2'."
    exit 1
    ;;
esac

# Validate temperature
if ! [[ "${TEMPERATURE}" =~ ^[0-9]+\.?[0-9]*$ ]]; then
  echo "Error: temperature must be a valid number."
  exit 1
fi

echo "============================================"
echo "Repeated Simulation Configuration:"
echo "  Number of runs  = ${NUM_RUNS}"
echo "  Model           = ${MODEL}"
echo "  Input file      = ${INPUT_FILE}"
echo "  Graph version   = ${GRAPH_VERSION}"
echo "  Temperature     = ${TEMPERATURE}"
echo "  Nodes/cluster   = ${NODES_VALUE}"
echo "============================================"
echo

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
  
  # Clean up Docker resources to free disk space
  echo "🧹 Cleaning up Docker resources..."
  docker volume prune -f 2>/dev/null || true
  docker system prune -f 2>/dev/null || true
  echo "✅ Docker cleanup completed."
}
trap cleanup EXIT

echo "Creating configuration backup at: ${BACKUP_FILE}"
cp "${CONFIG_FILE}" "${BACKUP_FILE}"

# Arrays to track results
declare -a RUN_STATUS
declare -a RUN_DESC

# Run the simulation NUM_RUNS times
for run_num in $(seq 1 "${NUM_RUNS}"); do
  echo "============================================"
  echo "Simulation Run ${run_num} of ${NUM_RUNS}:"
  echo "  model           = ${MODEL}"
  echo "  input_json      = ${INPUT_FILE}"
  echo "  temperature     = ${TEMPERATURE}"
  echo "  graph_version   = ${GRAPH_VERSION}"
  echo "============================================"

  # Restore original config before applying changes
  cp "${BACKUP_FILE}" "${CONFIG_FILE}"

  # Update AI engine parameters in config.yaml
  yq -i '.["ai-engine"].ai.selected_model = "'"${MODEL}"'"' "${CONFIG_FILE}"
  yq -i '.["ai-engine"].data.input_json = "'"${INPUT_FILE}"'"' "${CONFIG_FILE}"
  yq -i '.["ai-engine"].ai.multi_agent.graph_version = "'"${GRAPH_VERSION}"'"' "${CONFIG_FILE}"
  yq -i '.["ai-engine"].ai.multi_agent.generation_config.temperature = '"${TEMPERATURE}" "${CONFIG_FILE}"

  # Adjust cluster size (nodes per member) with CPU and memory
  yq -i ".clusters.member1.nodes = ${NODES_VALUE}" "${CONFIG_FILE}"
  yq -i '.clusters.member1.cpu = "'"${CPU_VALUE}"'"' "${CONFIG_FILE}"
  yq -i '.clusters.member1.memory = "'"${MEMORY_VALUE}"'"' "${CONFIG_FILE}"
  yq -i ".clusters.member1.autoscaler = false" "${CONFIG_FILE}"
  
  yq -i ".clusters.member2.nodes = ${NODES_VALUE}" "${CONFIG_FILE}"
  yq -i '.clusters.member2.cpu = "'"${CPU_VALUE}"'"' "${CONFIG_FILE}"
  yq -i '.clusters.member2.memory = "'"${MEMORY_VALUE}"'"' "${CONFIG_FILE}"
  yq -i ".clusters.member2.autoscaler = true" "${CONFIG_FILE}"

  echo "Configuration applied to ${CONFIG_FILE}."

  # Ensure simulator uses the same input file as configured for the AI engine
  SIM_INPUT_SRC="${ROOT_DIR}/simulator/data/${INPUT_FILE}"
  SIM_INPUT_DST="${ROOT_DIR}/simulator/data/input.json"
  if [ -f "${SIM_INPUT_SRC}" ]; then
    echo "Syncing simulator input: ${SIM_INPUT_SRC} -> ${SIM_INPUT_DST}"
    cp "${SIM_INPUT_SRC}" "${SIM_INPUT_DST}"
  else
    echo "Warning: simulator input source file not found: ${SIM_INPUT_SRC}"
  fi

  desc="Run ${run_num}/${NUM_RUNS} | Model=${MODEL} | Input=${INPUT_FILE} | Temp=${TEMPERATURE} | Graph=${GRAPH_VERSION}"
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
      if ! sudo cp "${ROOT_DIR}/simulator/data/${INPUT_FILE}" "${LAST_RUN_DIR%/}/input_used.json"; then
        echo "Warning: failed to copy input file to ${LAST_RUN_DIR}."
      fi

      echo "Generating plots with analyzer for ${TIMESTAMP}..."
      if ! (cd "${ROOT_DIR}/analyzer" && make generate-plots "${TIMESTAMP}"); then
        echo "❌ Failed to generate plots with analyzer."
        status="FAILED (generate-plots)"
      fi

      # Rename simulator and analyzer output directories with run number
      safe_model="${MODEL//\//-}"
      safe_model="${safe_model// /_}"
      input_base="$(basename "${INPUT_FILE}" .json)"
      base_name="${safe_model}_${input_base}_${GRAPH_VERSION}_${TEMPERATURE}"
      
      # Find next available run number to avoid conflicts
      actual_run_num="${run_num}"
      while [ -d "${ROOT_DIR}/simulator/data/output/${base_name}_run${actual_run_num}" ] || \
            [ -d "${ROOT_DIR}/analyzer/output/${base_name}_run${actual_run_num}" ]; do
        actual_run_num=$((actual_run_num + 1))
      done
      
      if [ "${actual_run_num}" != "${run_num}" ]; then
        echo "Note: run${run_num} directories already exist, using run${actual_run_num} instead."
      fi
      
      new_name="${base_name}_run${actual_run_num}"

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

  RUN_STATUS[run_num]="${status}"
  RUN_DESC[run_num]="${desc}"

  echo "Simulation run ${run_num} finished with status: ${status}."
  
  # Clean up Docker volumes between runs to prevent disk space buildup
  if [ "${run_num}" -lt "${NUM_RUNS}" ]; then
    echo "🧹 Cleaning Docker volumes before next run..."
    docker volume prune -f 2>/dev/null || true
    echo "✅ Docker cleanup completed. Ready for next run."
  fi
  echo
done

echo "Restoring original configuration at ${CONFIG_FILE}."
cp "${BACKUP_FILE}" "${CONFIG_FILE}"

echo "============================================"
echo "Repeated Simulations Summary:"
echo "  Total runs:   ${NUM_RUNS}"

success_count=0
fail_count=0
for i in $(seq 1 "${NUM_RUNS}"); do
  if [[ "${RUN_STATUS[i]}" == "SUCCESS" ]]; then
    success_count=$((success_count + 1))
  else
    fail_count=$((fail_count + 1))
  fi
done

echo "  Successful:   ${success_count}"
echo "  Failed:       ${fail_count}"
echo "--------------------------------------------"
echo "Details:"
for i in $(seq 1 "${NUM_RUNS}"); do
  echo "  ${i}. ${RUN_STATUS[i]} | ${RUN_DESC[i]}"
done
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

echo "All repeated simulations finished."
echo "You can find outputs in: ${ROOT_DIR}/simulator/data/output/"
