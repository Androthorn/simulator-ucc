#!/usr/bin/env bash

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPEAT_SCRIPT="${ROOT_DIR}/run_repeated_simulations.sh"

# Help / usage
if [ "${1-}" = "-h" ] || [ "${1-}" = "--help" ]; then
  script_name="$(basename "$0")"
  cat <<EOF
Usage: ${script_name} [OPTIONS]

Runs the repeated simulations script for multiple AI models sequentially.
Each model will run 10 consecutive simulations (configurable).

OPTIONS:
  -n, --num-runs NUM        Number of simulations per model (default: 10)
  -i, --input INPUT         Input file: 'const' or 'varia' (default: const)
  -g, --graph GRAPH         Graph version: 'v1' or 'v2' (default: v2)
  -t, --temperature TEMP    Temperature value (default: 0.1)
  -h, --help                Show this help message

Models that will be tested:
  1. anthropic-claude-haiku-4.5
  2. google-gemini-2.5-flash
  3. openai-gpt-5-mini

Examples:
  ${script_name}                            # Run 10 simulations per model with defaults
  ${script_name} -n 5                       # Run 5 simulations per model
  ${script_name} -n 10 -i varia -g v2       # Run 10 simulations with custom settings
EOF
  exit 0
fi

# Default values
NUM_RUNS=10
INPUT_TYPE="const"
GRAPH_VERSION="v2"
TEMPERATURE=0.1

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
    *)
      echo "Unknown option: $1"
      echo "Use -h or --help for usage information."
      exit 1
      ;;
  esac
done

# Define the models to test
MODELS=(
  "anthropic-claude-haiku-4.5"
  "google-gemini-2.5-flash"
  "openai-gpt-5-mini"
)

echo "============================================"
echo "Multi-Model Comparison Configuration:"
echo "  Models to test: ${#MODELS[@]}"
echo "  Runs per model: ${NUM_RUNS}"
echo "  Input file:     ${INPUT_TYPE}"
echo "  Graph version:  ${GRAPH_VERSION}"
echo "  Temperature:    ${TEMPERATURE}"
echo "============================================"
echo

# Check if the repeated simulations script exists
if [ ! -f "${REPEAT_SCRIPT}" ]; then
  echo "Error: repeated simulations script not found at: ${REPEAT_SCRIPT}"
  exit 1
fi

# Check if the script is executable
if [ ! -x "${REPEAT_SCRIPT}" ]; then
  echo "Making ${REPEAT_SCRIPT} executable..."
  chmod +x "${REPEAT_SCRIPT}"
fi

# Track results for each model
declare -a MODEL_STATUS
declare -a MODEL_DESC

# Run simulations for each model
for idx in "${!MODELS[@]}"; do
  model_num=$((idx + 1))
  model="${MODELS[idx]}"
  
  echo "════════════════════════════════════════════"
  echo "Starting Model ${model_num}/${#MODELS[@]}: ${model}"
  echo "════════════════════════════════════════════"
  echo
  
  # Run the repeated simulations script with the current model
  if "${REPEAT_SCRIPT}" -n "${NUM_RUNS}" -i "${INPUT_TYPE}" -g "${GRAPH_VERSION}" -t "${TEMPERATURE}" -m "${model}"; then
    MODEL_STATUS[idx]="SUCCESS"
    MODEL_DESC[idx]="Model: ${model} (${NUM_RUNS} runs)"
    echo
    echo "✅ Successfully completed all runs for: ${model}"
  else
    MODEL_STATUS[idx]="FAILED"
    MODEL_DESC[idx]="Model: ${model} (${NUM_RUNS} runs)"
    echo
    echo "❌ Failed during runs for: ${model}"
    echo "Continuing with next model..."
  fi
  
  echo
  
  # Add a pause between models to ensure clean separation
  if [ $((idx + 1)) -lt "${#MODELS[@]}" ]; then
    echo "⏸️  Pausing for 30 seconds before next model..."
    sleep 30
    echo
  fi
done

echo "════════════════════════════════════════════"
echo "Multi-Model Comparison Summary:"
echo "════════════════════════════════════════════"
echo "Configuration:"
echo "  Runs per model: ${NUM_RUNS}"
echo "  Input file:     ${INPUT_TYPE}"
echo "  Graph version:  ${GRAPH_VERSION}"
echo "  Temperature:    ${TEMPERATURE}"
echo "--------------------------------------------"
echo "Results:"

success_count=0
fail_count=0
for idx in "${!MODELS[@]}"; do
  model_num=$((idx + 1))
  if [[ "${MODEL_STATUS[idx]}" == "SUCCESS" ]]; then
    success_count=$((success_count + 1))
    status_symbol="✅"
  else
    fail_count=$((fail_count + 1))
    status_symbol="❌"
  fi
  echo "  ${model_num}. ${status_symbol} ${MODEL_STATUS[idx]} | ${MODEL_DESC[idx]}"
done

echo "--------------------------------------------"
echo "Summary:"
echo "  Total models:   ${#MODELS[@]}"
echo "  Successful:     ${success_count}"
echo "  Failed:         ${fail_count}"
echo "  Total runs:     $((NUM_RUNS * ${#MODELS[@]}))"
echo "════════════════════════════════════════════"
echo
echo "All multi-model simulations finished."
echo "You can find outputs in: ${ROOT_DIR}/simulator/data/output/"
echo "And analyzer results in: ${ROOT_DIR}/analyzer/output/"
