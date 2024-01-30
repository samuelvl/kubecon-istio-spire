#!/bin/sh
set -o nounset

export ISTIO_NAMESPACE="istio-system"
export ISTIO_GW_NAMESPACE="istio-gateways"
export ISTIO_GW_BASE_PORT_HTTP=31080
export ISTIO_GW_BASE_PORT_HTTPS=31443
export ISTIO_PORT_OFFSET=1000

BIN_DIR=${BIN_DIR:-.}
ISTIO_CLI="${BIN_DIR}/istioctl"
ISTIO_VERSION="1.20.2"

istio_install_cli() {
  echo "Downloading istioctl tool to ${BIN_DIR} output folder"

  ARCH="$(uname -m)"
  if [ "$ARCH" = "x86_64" ]; then
    export ARCH="linux-amd64"
  elif [ "$ARCH" = "aarch64" ]; then
    export ARCH="osx-arm64"
  fi

  mkdir -p "${BIN_DIR}"
  curl -L -s \
    "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istioctl-${ISTIO_VERSION}-${ARCH}.tar.gz" | tar -xvz -C "${BIN_DIR}"
  chmod +x "${ISTIO_CLI}"
}

istio_install() {
  istio_install_cli

  clusters_context="$*"
  cluster_counter=0
  for context in ${clusters_context}; do
    echo "installing istio in ${context} cluster"
    istio_install_control_plane "${context}"
    istio_install_gateway "${cluster_counter}" "${context}"
    cluster_counter=$((cluster_counter + 1))
  done
}

istio_install_control_plane() {
  context="${1}"
  kubectl create --context="${context}" namespace "${ISTIO_NAMESPACE}" || true

  # Install Istio control plane
  cat <<EOF | istioctl install --context "${context}" -y --verify -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: control-plane
  namespace: ${ISTIO_NAMESPACE}
spec:
  profile: minimal
  meshConfig:
    accessLogFile: /dev/stdout
    outboundTrafficPolicy:
      mode: ALLOW_ANY
  values:
    global:
      defaultPodDisruptionBudget:
        enabled: false
    pilot:
      autoscaleEnabled: false
EOF
}

istio_install_gateway() {
  index="${1}"
  context="${2}"
  kubectl create --context="${context}" namespace "${ISTIO_GW_NAMESPACE}" || true

  # Calculate unique port numbers for this cluster
  port_offset=$((index * ISTIO_PORT_OFFSET))
  istio_gw_port_http=$((ISTIO_GW_BASE_PORT_HTTP + port_offset))
  istio_gw_port_https=$((ISTIO_GW_BASE_PORT_HTTPS + port_offset))

  # Install Istio GW
  cat <<EOF | istioctl install --context "${context}" -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: istio-ingressgateway
  namespace: ${ISTIO_NAMESPACE}
spec:
  profile: empty
  meshConfig:
    accessLogFile: /dev/stdout
  components:
    ingressGateways:
      - name: istio-ingressgateway
        namespace: ${ISTIO_GW_NAMESPACE}
        enabled: true
        label:
          istio: ingressgateway
          traffic: north-south
        k8s:
          service:
            type: NodePort
            selector:
              app: istio-ingressgateway
              istio: ingressgateway
              traffic: north-south
            ports:
              - port: 80
                targetPort: 8080
                name: http2
                nodePort: ${istio_gw_port_http}
              - port: 443
                targetPort: 8443
                name: https
                nodePort: ${istio_gw_port_https}
          overlays:
            - apiVersion: apps/v1
              kind: Deployment
              name: istio-ingressgateway
              patches:
                - path: spec.template.spec.containers.[name:istio-proxy].resources
                  value:
                    requests:
                      cpu: 100m
                      memory: 128Mi
                    limits: {}
  values:
    global:
      defaultPodDisruptionBudget:
        enabled: false
    gateways:
      istio-ingressgateway:
        autoscaleEnabled: false
        injectionTemplate: gateway
EOF
}
