SHELL := /bin/bash
export PATH := $(PATH):/usr/local/go/bin

ACTUATOR_MODE ?= auto

.PHONY: all setup-and-start setup-and-start-human start setup-kubernetes-infra stop-all-containers restart-all-containers help start-auto-mode start-human-loop-mode run-auto-mode run-all-containers run-all-containers-human

# Default target: sets up infrastructure and runs the simulator
all: setup-and-start

# Sets up infrastructure and runs in human-in-the-loop mode
setup-and-start-human: setup-kubernetes-infra stop-all-containers run-all-containers-human start

# Sets up Kubernetes infrastructure
setup-kubernetes-infra:
	@echo -e "\\e[35mStarting Kubernetes infrastructure setup (scripts/main.sh)...\\e[0m"
	@( \
		cd scripts && ./main.sh; \
	)
	@echo -e "\\e[35mKubernetes infrastructure setup completed.\\e[0m"

# Starts all required containers via docker compose
run-all-containers:
	@echo "Updating compose.yaml paths with the user's HOME..."
	@echo scripts/replace_paths_in_compose.sh
	@echo "Starting all necessary containers via docker compose..."
	@docker compose -f compose.yaml up --build -d
	@echo "All containers started successfully."

# Run containers in human-in-the-loop mode (UI review required)
run-all-containers-human:
	@echo "Starting all containers in HUMAN-IN-THE-LOOP mode..."
	@echo "Updating compose.yaml paths with the user's HOME..."
	@echo scripts/replace_paths_in_compose.sh
	@echo "Starting all necessary containers via docker compose (ACTUATOR_MODE=human-in-the-loop)..."
	@ACTUATOR_MODE=human-in-the-loop docker compose -f compose.yaml up --build -d
	@echo "All containers started successfully in HUMAN-IN-THE-LOOP mode."
	@echo "🎯 Actuator UI available at: http://localhost:5173"

# Sets up the complete infrastructure
setup: stop-kubernetes-infra stop-all-containers setup-kubernetes-infra run-all-containers

# Starts only the Go simulator (assumes infrastructure is already set up)
start:
	@(cd simulator/cmd && go run main.go)

# Sets up the complete infrastructure and runs the simulator
setup-and-start: setup start

# Runs ADRS refinement on the latest simulation output
adrs-refine:
	@echo -e "\\\e[35mRunning ADRS evaluate-and-refine on latest simulation...\\\e[0m"
	@LAST_AN_DIR=$$(ls -1dt analyzer/output/*/ 2>/dev/null | head -1); \
	if [ -z "$$LAST_AN_DIR" ]; then \
		echo "Error: no analyzer output found in analyzer/output/"; \
		exit 1; \
	fi; \
	echo "Using analyzer output: $$LAST_AN_DIR"; \
	adrs evaluate-and-refine \
		--analyzer-output "$$LAST_AN_DIR" \
		--simulator-path . \
		--objective adrs_objective.json \
		--prompt-file consolidator_agent.txt
	@echo -e "\\\e[35mADRS refinement completed.\\\e[0m"

# Sets up infrastructure, runs the simulator, and then refines the prompt
setup-and-start-with-refinement: setup-and-start adrs-refine


# Cleans all documents from all collections in the mongo container
clean-mongo-db:
	@echo "Cleaning all documents from all collections in mongo container..."
	@container_id=$$(sudo docker ps -q -f name=mongo); \
	if [ -z "$$container_id" ]; then \
		echo "Mongo container is not running. Nothing to clean."; \
		exit 0; \
	fi; \
	js='dbs=db.getMongo().getDBNames().filter(function(x){return ["admin","local","config"].indexOf(x)<0});dbs.forEach(function(dbName){db=db.getSiblingDB(dbName);db.getCollectionNames().forEach(function(coll){db[coll].deleteMany({});});});'; \
	sudo docker exec $$container_id mongosh --quiet --eval "$$js"; \
	echo "All documents removed from all user collections via mongosh in container."

restart-all-containers: stop-all-containers run-all-containers
	@echo "All services have been fully restarted."

# Para derrubar os containers KIND do cluster
stop-kubernetes-infra:
	@echo "Parando containers KIND do cluster..."
	docker rm -f member1-control-plane member2-control-plane karmada-host-control-plane || true
	@echo "Containers KIND removidos."

# Stops and removes all simulator containers, volumes, and images
stop-all-containers:
	@echo "Stopping and removing all containers and volumes defined in compose.yaml..."
	@echo "Preservando imagens puxadas (mongo, kindest/node, karmada/*) p/ evitar re-download a cada run..."
	@sudo docker compose -f compose.yaml down -v --rmi local 2>/dev/null || sudo docker compose -f compose.yaml down -v
	@sudo docker image prune -f >/dev/null 2>&1 || true
	@echo "Cleanup process completed."

# ──────────────────────────────────────────────────────────────────────────────
# Important Notes
# - You must export the KUBECONFIG variable with the correct files
#   before running commands that use `kubectl`, such as the Broker.
#   Example:
#
#     export KUBECONFIG=~/.kube/karmada.config
#     # or (to view multiple clusters)
#     export KUBECONFIG=~/.kube/karmada.config:~/.kube/members.config
#
# - Without this, the Broker will not be able to create deployments and jobs correctly.
# ──────────────────────────────────────────────────────────────────────────────
# Generates input data for simulation
generate-input:
	@echo "Generating input data for simulation..."
	@(cd simulator/data/input_generator && ../../../venv/bin/python main.py)
	@echo "Input data generated successfully."

# Help

help:
	@echo "Available targets:"
	@echo "  all                      : Alias for 'setup-and-start'."
	@echo "  setup-and-start          : Sets up infrastructure, starts all containers and runs the simulator."
	@echo "  start                    : Starts ONLY the Go simulator (assumes infrastructure and containers are already running)."
	@echo "  ---"
	@echo "  Container Management:"
	@echo "    run-all-containers     : Starts all required containers via docker compose."
	@echo "    restart-all-containers : Stops, removes, and recreates all containers, volumes, and images."
	@echo "    stop-all-containers    : Stops and removes all simulator containers, volumes and images via docker compose."
	@echo "  ---"
	@echo "  Database:"
	@echo "    clean-mongo-db         : Stops the mongo container and removes its data volume."
	@echo "  ---"
	@echo "  Data Generation:"
	@echo "    generate-input         : Generates input data for simulation using the input_generator."
	@echo "  ---"
	@echo "  Infrastructure:"
	@echo "    setup-kubernetes-infra : Runs scripts/main.sh to set up Kubernetes infrastructure."
	@echo "  ---"
	@echo "  help                     : Shows this help message."