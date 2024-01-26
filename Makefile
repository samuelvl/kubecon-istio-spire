ROOT_DIR     := $(shell pwd)
OUTPUT_DIR   := $(ROOT_DIR)/_output
BIN_DIR      := $(OUTPUT_DIR)/bin
CLUSTER_NAME := spire-cluster

.PHONY: install
install: setup-test-cluster install-spire install-istio

# Kind clusters
.PHONY: setup-test-cluster
setup-test-cluster:
	BIN_DIR=$(BIN_DIR) ./scripts/lib/kind.sh kind_create_cluster "$(CLUSTER_NAME)"

.PHONY: destroy-test-cluster
destroy-test-cluster:
	BIN_DIR=$(BIN_DIR) ./scripts/lib/kind.sh kind_delete_cluster "$(CLUSTER_NAME)"

# Install Spire stack
.PHONY: install-spire
install-spire:
	./scripts/lib/spire.sh spire_install "kind-$(CLUSTER_NAME)"

# Install Istio
.PHONY: install-istio
install-istio:
	./scripts/lib/istio.sh istio_install "kind-$(CLUSTER_NAME)"

# Clean up
.PHONY: clean
clean: destroy-test-cluster
	rm -rf $(BIN_DIR)/*
