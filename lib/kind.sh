#!/bin/sh
set -o nounset

BIN_DIR=${BIN_DIR:-.}
KIND_CLI="${BIN_DIR}/kind"
KIND_VERSION="0.20.0"

kind_install_cli() {
  echo "Downloading kind cli tool to ${BIN_DIR} output folder"
  curl -L -s -o "${KIND_CLI}" \
    https://github.com/kubernetes-sigs/kind/releases/download/v${KIND_VERSION}/kind-linux-amd64
  chmod +x "${KIND_CLI}"
}

kind_create_cluster() {
  cluster_name="${1}"

  kind_install_cli

  ${KIND_CLI} get clusters | grep "${cluster_name}" >/dev/null && {
    echo "Kind cluster \"${cluster_name}\" already exists"
    return
  } || true

  cat <<EOF | ${KIND_CLI} create cluster --name "${cluster_name}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  image: docker.io/kindest/node:v1.27.3@sha256:3966ac761ae0136263ffdb6cfd4db23ef8a83cba8a463690e98317add2c9ba72
  extraPortMappings:
    - containerPort: 31080
      hostPort: 31080
      protocol: TCP
    - containerPort: 31443
      hostPort: 31443
      protocol: TCP
    - containerPort: 31445
      hostPort: 31445
      protocol: TCP
- role: worker
  image: docker.io/kindest/node:v1.27.3@sha256:3966ac761ae0136263ffdb6cfd4db23ef8a83cba8a463690e98317add2c9ba72
- role: worker
  image: docker.io/kindest/node:v1.27.3@sha256:3966ac761ae0136263ffdb6cfd4db23ef8a83cba8a463690e98317add2c9ba72
EOF
}

kind_delete_cluster() {
  cluster_name="${1}"

  kind_install_cli

  ${KIND_CLI} get clusters | grep "${cluster_name}" >/dev/null && {
    ${KIND_CLI} delete clusters "${cluster_name}"
  } || true
}

"$@"
