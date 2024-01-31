ROOT_DIR          := $(shell pwd)
OUTPUT_DIR        := $(ROOT_DIR)/_output
BIN_DIR           := $(OUTPUT_DIR)/.bin
CLUSTER_BASE_NAME := istio-cluster

.PHONY: install
install: setup-test-clusters install-istio

# Kind clusters
.PHONY: setup-test-clusters
setup-test-clusters:
	BIN_DIR=$(BIN_DIR) . ./scripts/lib/kind.sh; \
	kind_create_clusters "$(CLUSTER_BASE_NAME)-1" "$(CLUSTER_BASE_NAME)-2"

.PHONY: cleanup-test-clusters
cleanup-test-clusters:
	BIN_DIR=$(BIN_DIR) . ./scripts/lib/kind.sh; \
	kind_delete_clusters "$(CLUSTER_BASE_NAME)-1" "$(CLUSTER_BASE_NAME)-2"

# Install Istio
.PHONY: install-istio
install-istio:
	BIN_DIR=$(BIN_DIR) . ./scripts/lib/istio.sh; \
	istio_install "kind-$(CLUSTER_BASE_NAME)-1" "kind-$(CLUSTER_BASE_NAME)-2"

# Install Spire stack
.PHONY: install-spire
install-spire:
	BIN_DIR=$(BIN_DIR) . ./scripts/lib/spire.sh; \
	spire_install "kind-$(CLUSTER_BASE_NAME)-1" "kind-$(CLUSTER_BASE_NAME)-2"

# Install sample apps
.PHONY: deploy-apps
deploy-apps:
	BIN_DIR=$(BIN_DIR) . ./scripts/lib/app.sh; \
	deploy_hello_world_and_sleep_apps "kind-$(CLUSTER_BASE_NAME)-1" "kind-$(CLUSTER_BASE_NAME)-2"

# Clean up
.PHONY: clean
clean: cleanup-test-clusters
	rm -rf $(BIN_DIR)/*
