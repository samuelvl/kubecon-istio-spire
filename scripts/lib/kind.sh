#!/bin/sh
set -o nounset

. "./scripts/lib/istio.sh"

BIN_DIR=${BIN_DIR:-.}
KIND_CLI="${BIN_DIR}/kind"
KIND_VERSION="0.20.0"
KIND_NODE_IMAGE="docker.io/kindest/node:v1.27.3@sha256:3966ac761ae0136263ffdb6cfd4db23ef8a83cba8a463690e98317add2c9ba72"

kind_install_cli() {
  echo "Downloading kind cli tool to ${BIN_DIR} output folder"

  ARCH="$(uname -m)"
  if [ "$ARCH" = "x86_64" ]; then
    export ARCH="amd64"
  elif [ "$ARCH" = "aarch64" ]; then
    export ARCH="arm64"
  fi

  mkdir -p "${BIN_DIR}"
  curl -L -s -o "${KIND_CLI}" \
    "https://github.com/kubernetes-sigs/kind/releases/download/v${KIND_VERSION}/kind-linux-${ARCH}"
  chmod +x "${KIND_CLI}"
}

kind_create_clusters() {
  kind_install_cli

  clusters="$*"
  cluster_counter=0
  for cluster_name in ${clusters}; do
    if kind_cluster_exists "${cluster_name}"; then
      echo "Kind cluster \"${cluster_name}\" already exists"
      continue
    fi

    # Calculate unique port numbers for this cluster
    port_offset=$((cluster_counter * ISTIO_PORT_OFFSET))
    istio_gw_port_http=$((ISTIO_GW_BASE_PORT_HTTP + port_offset))
    istio_gw_port_https=$((ISTIO_GW_BASE_PORT_HTTPS + port_offset))

    cat <<EOF | ${KIND_CLI} create cluster --name "${cluster_name}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  image: ${KIND_NODE_IMAGE}
  extraPortMappings:
    - containerPort: 31080
      hostPort: ${istio_gw_port_http}
      protocol: TCP
    - containerPort: 31443
      hostPort: ${istio_gw_port_https}
      protocol: TCP
EOF
    cluster_counter=$((cluster_counter + 1))
  done
}

kind_delete_clusters() {
  clusters="$*"
  for cluster_name in ${clusters}; do
    if kind_cluster_exists "${cluster_name}"; then
      ${KIND_CLI} delete clusters "${cluster_name}"
    fi
  done
}

kind_cluster_exists() {
  ${KIND_CLI} get clusters | grep "${cluster_name}" >/dev/null
}
