#!/bin/sh
set -u -o errexit -x

. "./scripts/lib/spire.sh"
. "./scripts/lib/istio.sh"

BIN_DIR=${BIN_DIR:-.}
KIND_CLI="${BIN_DIR}/kind"
KIND_VERSION="0.20.0"
KIND_NODE_IMAGE="docker.io/kindest/node:v1.29.1@sha256:3966ac761ae0136263ffdb6cfd4db23ef8a83cba8a463690e98317add2c9ba72"

kind_install_cli() {
  if [ -f "${KIND_CLI}" ]; then
    echo "${KIND_CLI} already exists"
    return
  fi

  echo "Downloading kind cli tool to ${BIN_DIR} output folder"

  ARCH="$(uname -m)"
  if [ "$ARCH" = "x86_64" ]; then
    ARCH="amd64"
    OS="linux"
  elif [ "$ARCH" = "arm64" ]; then
    ARCH="arm64"
    OS="darwin"
  fi

  mkdir -p "${BIN_DIR}"
  curl -L -s -o "${KIND_CLI}" \
    "https://github.com/kubernetes-sigs/kind/releases/download/v${KIND_VERSION}/kind-${OS}-${ARCH}"
  chmod +x "${KIND_CLI}"
}

kind_create_clusters() {
  kind_install_cli

  clusters="${1}"
  cluster_counter=0
  for cluster in ${clusters}; do
    if kind_cluster_exists "${cluster}"; then
      echo "Kind cluster \"${cluster}\" already exists"
      continue
    fi

    cat <<EOF | tee /dev/tty | ${KIND_CLI} create cluster --name "${cluster}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  podSubnet: $(kind_pods_cidr "${cluster_counter}")
  serviceSubnet: $(kind_svcs_cidr "${cluster_counter}")
nodes:
- role: control-plane
  image: ${KIND_NODE_IMAGE}
  extraPortMappings:
    - containerPort: ${SPIRE_SERVER_BASE_PORT_GRPC}
      hostPort: $(spire_unique_port "${cluster_counter}" "${SPIRE_SERVER_BASE_PORT_GRPC}")
      protocol: TCP
    - containerPort: ${SPIRE_SERVER_BASE_PORT_FEDERATION}
      hostPort: $(spire_unique_port "${cluster_counter}" "${SPIRE_SERVER_BASE_PORT_FEDERATION}")
      protocol: TCP
    - containerPort: ${ISTIO_GW_BASE_PORT_HTTP}
      hostPort: $(istio_unique_port "${cluster_counter}" "${ISTIO_GW_BASE_PORT_HTTP}")
      protocol: TCP
    - containerPort: ${ISTIO_GW_BASE_PORT_HTTPS}
      hostPort: $(istio_unique_port "${cluster_counter}" "${ISTIO_GW_BASE_PORT_HTTPS}")
      protocol: TCP
EOF
    kind_wait_for_nodes "kind-${cluster}"
    cluster_counter=$((cluster_counter + 1))
  done

  # Enable cross-cluster communication
  for cluster in ${clusters}; do
    for remote_cluster in ${clusters}; do
      if [ "${cluster}" != "${remote_cluster}" ]; then
        kind_join_cluster_network "kind-${cluster}" "kind-${remote_cluster}"
      fi
    done
  done
}

kind_wait_for_nodes() {
  context="${1}"
  for node in $(kubectl --context="${context}" get nodes -o name); do
    for _ in $(seq 60); do
      if [ "$(kubectl --context="${context}" get "${node}" -o jsonpath='{.spec.podCIDR}')" != "" ]; then break; fi
      sleep 5
    done
  done
}

kind_join_cluster_network() {
  context="${1}"
  remote_context="${2}"
  for remote_node in $(kubectl --context="${remote_context}" get nodes -o name); do
    for node in $(kubectl --context="${context}" get nodes -o name); do
      docker exec -it "${node##*/}" /bin/sh -c "$(kind_get_node_ip_route "${remote_context}" "${remote_node}")"
    done
  done
}

kind_get_node_ip_route() {
  context="${1}"
  node="${2}"
  kubectl --context="${context}" get "${node}" \
    -o jsonpath='{"ip route add "}{.spec.podCIDR}{" via "}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}'
}

kind_delete_clusters() {
  clusters="${1}"
  for cluster in ${clusters}; do
    if kind_cluster_exists "${cluster}"; then
      ${KIND_CLI} delete clusters "${cluster}"
    fi
  done
}

kind_cluster_exists() {
  cluster="${1}"
  ${KIND_CLI} get clusters | grep "${cluster}" >/dev/null
}

kind_pods_cidr() {
  cluster_index="${1}"
  echo "10.$((cluster_index)).0.0/16"
}

kind_svcs_cidr() {
  cluster_index="${1}"
  echo "10.$((cluster_index + 100)).0.0/16"
}
