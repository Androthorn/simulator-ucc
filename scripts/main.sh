#!/bin/bash
# -----------------------------------------------------------------------------
# Main Orchestrator – provisions the full simulation stack using Karmada,
# KWOK, Cluster Autoscaler, and Prometheus, driven by a YAML config file.
# -----------------------------------------------------------------------------
# ‣ Behaviour
#   • Loads cluster definitions from initialization.yaml.
#   • Installs prerequisites, generates manifests, starts Karmada.
#   • Deploys Prometheus, KWOK, Cluster Autoscaler (conditionally), and nodes.
# -----------------------------------------------------------------------------
COLOR="\033[1;32m"  # Green – this script's identity color
RESET="\033[0m"

set -euo pipefail
trap 'echo -e "${COLOR}❌ Error in ${BASH_SOURCE[0]}:$LINENO – $BASH_COMMAND${RESET}"' ERR

# -----------------------------------------------------------------------------
# Setup Python venv and dependencies for Analyzer
# -----------------------------------------------------------------------------
echo -e "${COLOR}🐍 Setting up Python venv for Analyzer...${RESET}"
SCRIPT_DIR="$(dirname "$0")"
pushd "$SCRIPT_DIR" > /dev/null
chmod +x setup_venv.sh
./setup_venv.sh
popd > /dev/null
echo -e "${COLOR}✅ Python venv ready.${RESET}"

# -----------------------------------------------------------------------------
# 1. Ensure all scripts are executable
# -----------------------------------------------------------------------------
chmod +x install_prerequisites.sh generate_manifests.sh install_karmada.sh \
        install_prometheus.sh install_kwok.sh install_autoscaler.sh \
        taint_control_plane.sh create_kwok_nodes.sh load_config.sh

echo -e "${COLOR}[1/8] 📦 Installing prerequisites...${RESET}"
./install_prerequisites.sh

# -----------------------------------------------------------------------------
# 2. Load all variables 
# -----------------------------------------------------------------------------
# SIM_CONFIG_SRC (path da config a usar) parametriza a infra; default = config.yaml congelada.
CONFIG_FILE="${SIM_CONFIG_SRC:-../simulator/data/config.yaml}"
[[ ! -f $CONFIG_FILE ]] && { echo "❌ $CONFIG_FILE not found."; exit 1; }

echo -e "${COLOR}[2/8] 📦 Load configuration...${RESET}"
source ./load_config.sh $CONFIG_FILE

echo -e "\n🔧 Loaded configuration from $CONFIG_FILE:"
echo "member1: $MEMBER1_NODES nodes, ${MEMBER1_CPU} CPU, ${MEMBER1_MEM} RAM"
echo "member2: $MEMBER2_NODES nodes, ${MEMBER2_CPU} CPU, ${MEMBER2_MEM} RAM, autoscaler=$MEMBER2_AUTOSCALER"
echo ""

# -----------------------------------------------------------------------------
# 3. Provision infrastructure
# -----------------------------------------------------------------------------
echo -e "${COLOR}[3/8] 📝 Generating configuration files...${RESET}"
./generate_manifests.sh

echo -e "${COLOR}[4/8] ☸️  Bringing up Karmada...${RESET}"
./install_karmada.sh
export KUBECONFIG=~/.kube/karmada.config

echo -e "${COLOR}[5/8] 📊 Installing Prometheus...${RESET}"
./install_prometheus.sh  # includes readiness check and port-forwards

# -----------------------------------------------------------------------------
# 4. Setup KWOK & Autoscaler stack
# -----------------------------------------------------------------------------
export KUBECONFIG=~/.kube/members.config

echo -e "${COLOR}[6/8] ☁️ Installing KWOK controller...${RESET}"
./install_kwok.sh

if [[ "${MEMBER2_AUTOSCALER:-true}" == "true" ]]; then
  echo -e "${COLOR}[7/8] ⚙️ Installing Cluster Autoscaler...${RESET}"
  ./install_autoscaler.sh
else
  echo -e "${COLOR}[7/8] ⚙️ Skipping Autoscaler installation (disabled in config)...${RESET}"
fi

echo -e "${COLOR}[8/8] 🧪 Applying taints and creating KWOK nodes...${RESET}"
./taint_control_plane.sh
./create_kwok_nodes.sh

# -----------------------------------------------------------------------------
# 5. Final message
# -----------------------------------------------------------------------------
echo -e "\n${COLOR}[🎉] Environment provisioned successfully!${RESET}"
