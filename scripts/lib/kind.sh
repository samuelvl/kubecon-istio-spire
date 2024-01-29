#!/bin/sh
set -o nounset

BIN_DIR=${BIN_DIR:-.}
KIND_CLI="${BIN_DIR}/kind"
KIND_VERSION="0.20.0"

kind_install_cli() {
  echo "Please specify your operating system (linux/mac):"
  read os_choice

  echo "Downloading kind cli tool to ${BIN_DIR} output folder"

  case $os_choice in
    linux)
      curl -L -s -o "${KIND_CLI}" \
        https://github.com/kubernetes-sigs/kind/releases/download/v${KIND_VERSION}/kind-linux-amd64
      ;;
    mac)
      curl -L -s -o "${KIND_CLI}" \
        https://github.com/kubernetes-sigs/kind/releases/download/v${KIND_VERSION}/kind-darwin-arm64
      ;;
    *)
      echo "Invalid input. Please specify 'linux' or 'mac'."
      return 1
      ;;
  esac

  chmod +x "${KIND_CLI}"
}

kind_create_cluster() {
  # Base port numbers
  base_control_plane_port=31080
  base_https_port=31443
  base_another_port=31445

  # Increment to ensure unique port numbers for each cluster
  increment=1000

  kind_install_cli

  for cluster_name in "$@"; do
    echo "Creating cluster: $cluster_name"

    # Calculate unique port numbers for this cluster
    control_plane_port=$((base_control_plane_port + increment))
    https_port=$((base_https_port + increment))
    another_port=$((base_another_port + increment))

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
      hostPort: ${control_plane_port}
      protocol: TCP
    - containerPort: 31443
      hostPort: ${https_port}
      protocol: TCP
    - containerPort: 31445
      hostPort: ${another_port}
      protocol: TCP
- role: worker
  image: docker.io/kindest/node:v1.27.3@sha256:3966ac761ae0136263ffdb6cfd4db23ef8a83cba8a463690e98317add2c9ba72
- role: worker
  image: docker.io/kindest/node:v1.27.3@sha256:3966ac761ae0136263ffdb6cfd4db23ef8a83cba8a463690e98317add2c9ba72
EOF

    # Increment the base port numbers for the next cluster
    base_control_plane_port=$((base_control_plane_port + increment))
    base_https_port=$((base_https_port + increment))
    base_another_port=$((base_another_port + increment))
  done
}


kind_delete_cluster() {
  for cluster_name in "$@"; do
    echo "Deleting cluster: $cluster_name"

    ${KIND_CLI} get clusters | grep "${cluster_name}" >/dev/null && {
      ${KIND_CLI} delete clusters "${cluster_name}"
    } || true
  done
}

"$@"
