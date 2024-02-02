#!/bin/sh
set -o nounset

export ISTIO_NAMESPACE="istio-system"
export ISTIO_GW_NAMESPACE="istio-gateways"
export ISTIO_GW_BASE_PORT_HTTP=31080
export ISTIO_GW_BASE_PORT_HTTPS=31443
export ISTIO_PORT_OFFSET=1000
export ISTIO_MESHID=mesh1
export ISTIO_NETWORK=network1

BIN_DIR=${BIN_DIR:-.}
ISTIO_CLI="${BIN_DIR}/istioctl"
ISTIO_VERSION="1.20.2"

istio_install() {
  istio_install_cli
  clusters_contexts=("$@")

  namespace="sample"
  versions=("v1" "v2")

  cluster_counter=0
  for context in "${clusters_contexts[@]}"; do
    echo "installing istio in ${context} cluster"
    istio_install_control_plane "${context}"
    istio_install_gateway "${cluster_counter}" "${context}"
    # Deploy HelloWorld app with the corresponding version
    version="${versions[cluster_counter]:-}"
    echo "Deploying HelloWorld ${version} in ${context}"
    deploy_helloworld "${context}" "${namespace}" "${version}"
    echo "Deploying Sleep app in ${context}"
    deploy_sleep "${context}" "${namespace}"
    cluster_counter=$((cluster_counter + 1))
  done

}

istio_install_cli (){
  echo "Downloading istioctl tool to ${BIN_DIR} output folder"

  ARCH="$(uname -m)"
  if [ "$ARCH" = "x86_64" ]; then
    export ARCH="linux-amd64"
  elif [ "$ARCH" = "arm64" ]; then
    export ARCH="osx-arm64"
  fi

  mkdir -p "${BIN_DIR}"
  curl -L -s \
    "https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istioctl-${ISTIO_VERSION}-${ARCH}.tar.gz" | tar -xvz -C "${BIN_DIR}"
  chmod +x "${ISTIO_CLI}"
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
      meshID: ${ISTIO_MESHID}
      multiCluster:
        clusterName: ${context} 
      network: ${ISTIO_NETWORK}
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

istio_enable_endpoint_discovery() {
  contexts=("$*")
  num_contexts=${#contexts[@]}

  for i in $(seq 0 $((num_contexts - 1))); do
    current_context="${contexts[i]}"
    target_context="${contexts[$(( (i + 1) % num_contexts ))]}"

    echo "Creating remote secret from ${current_context} and applying it to ${target_context}"

    ${ISTIO_CLI} create-remote-secret \
      --context="${current_context}" \
      --name="${current_context}" | \
      kubectl apply -f - --context="${target_context}"
  done
}

istio_deploy_app_helloworld() {
  context="$1"
  namespace="$2"
  version="$3"

  # Define the HelloWorld service YAML
  helloworld_service_yaml=$(cat <<EOF
apiVersion: v1
kind: Service
metadata:
  name: helloworld
  namespace: ${namespace}
spec:
  ports:
  - name: http
    port: 5000
  selector:
    app: helloworld
EOF
  )

  # Create namespace and label it for Istio sidecar injection
  kubectl create --context="${context}" namespace "${namespace}" || true
  kubectl label --context="${context}" namespace "${namespace}" istio-injection=enabled --overwrite

  # Apply the HelloWorld service YAML
  echo "$helloworld_service_yaml" | kubectl apply --context="${context}" -f -
  echo "version: ${version}"
  echo "context ${context}"
  # Deploy HelloWorld app
  kubectl apply --context="${context}" -n "${namespace}" -f \
    "https://raw.githubusercontent.com/istio/istio/release-1.20/samples/helloworld/helloworld.yaml" \
    -l app=helloworld -l version=${version}
}

istio_deploy_app_sleep() {
  context="$1"
  namespace="$2"

  kubectl apply --context="${context}" -n "${namespace}" -f \
    "https://raw.githubusercontent.com/istio/istio/release-1.20/samples/sleep/sleep.yaml"
}
