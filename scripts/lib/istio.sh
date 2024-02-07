#!/bin/sh
set -u -o errexit -x

export ISTIO_GW_BASE_PORT_HTTP=31080
export ISTIO_GW_BASE_PORT_HTTPS=31443
export ISTIO_PORT_OFFSET=1000

BIN_DIR=${BIN_DIR:-.}
ISTIO_CLI="${BIN_DIR}/istioctl"
ISTIO_VERSION="1.20.2"
ISTIO_NAMESPACE="istio-system"
ISTIO_GW_NAMESPACE="istio-gateways"
ISTIO_APPS_NAMESPACE="istio-apps"
ISTIO_MESHID=mesh1
ISTIO_NETWORK=network1
CERTS_DIR=certs

istio_install_cli() {
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

istio_install() {
  istio_install_cli

  clusters_contexts=("$@")
  cluster_counter=0

  namespace="sample"
  versions=("v1" "v2")

  for context in "${clusters_contexts[@]}"; do
    echo "Generate and apply istio certificates"   
    generate_and_apply_istio_certificates "${context}"

    echo "Installing Istio in ${context} cluster"
    istio_install_control_plane "${context}"
    istio_install_gateway "${cluster_counter}" "${context}"

    # Assuming versions are meant to be cycled through for each context
    version="${versions[cluster_counter]:-}"
    echo "Deploying HelloWorld ${version} in ${context}"
    istio_deploy_app_helloworld "${context}" "${ISTIO_APPS_NAMESPACE}" "${version}"
    echo "Deploying Sleep app in ${context}"
    istio_deploy_app_sleep "${context}" "${ISTIO_APPS_NAMESPACE}"

    cluster_counter=$((cluster_counter + 1))
  done

  istio_enable_endpoint_discovery "${clusters_contexts[@]}"
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

istio_deploy_app_helloworld() {
  context="${1}"
  namespace="${2}"
  version="${3}"

  # Create namespace and label it for Istio sidecar injection
  kubectl create --context="${context}" namespace "${namespace}" || true
  kubectl label --context="${context}" namespace "${namespace}" istio-injection=enabled --overwrite

  # Deploy Helloworld app
  kubectl apply --context="${context}" -n "${namespace}" -f \
    "https://raw.githubusercontent.com/istio/istio/release-1.20/samples/helloworld/helloworld.yaml" \
    -l app=helloworld -l version="${version}"

  # Apply the HelloWorld service YAML
  kubectl apply --context="${context}" -n "${namespace}" -f - <<EOF
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
}

istio_deploy_app_sleep() {
  context="${1}"
  namespace="${2}"

  # Create namespace and label it for Istio sidecar injection
  kubectl create --context="${context}" namespace "${namespace}" || true
  kubectl label --context="${context}" namespace "${namespace}" istio-injection=enabled --overwrite

  # Deploy Sleep app
  kubectl apply --context="${context}" -n "${namespace}" -f \
    "https://raw.githubusercontent.com/istio/istio/release-1.20/samples/sleep/sleep.yaml"
}

istio_enable_endpoint_discovery() {
  contexts=("$@")
  num_contexts=${#contexts[@]}

  for i in $(seq 0 $((num_contexts - 1))); do
    current_context="${contexts[i]}"
    target_context="${contexts[$(( (i + 1) % num_contexts ))]}"

    echo "Creating remote secret from ${current_context} and applying it to ${target_context}"

    # Adjust the context name to match the container naming convention
    # This removes the 'kind-' prefix and constructs the container name
    CONTAINER_NAME=$(echo "${current_context}" | sed 's/^kind-//')-control-plane

    # Extract the container ID using the adjusted container name
    CONTAINER_ID=$(docker ps --filter "name=${CONTAINER_NAME}" --format "{{.ID}}")

    # Dynamically get the API server IP address for the current context using docker inspect
    API_SERVER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${CONTAINER_ID}")

    # Construct the API server address using the container IP and the standard API server port (6443)
    API_SERVER_ADDRESS="https://${API_SERVER_IP}:6443"
    echo "API Server Address for context ${current_context}: $API_SERVER_ADDRESS"

    # Use the constructed API server address with --server option
    ${ISTIO_CLI} create-remote-secret \
      --context="${current_context}" \
      --name="${current_context}" \
      --server="${API_SERVER_ADDRESS}" | \
      kubectl apply -f - --context="${target_context}"
  done
}


function generate_and_apply_istio_certificates() {
    context="${1}"

    
    kubectl create --context="${context}" namespace "${ISTIO_NAMESPACE}" || true

    # Create the certs directory
    mkdir -p "${CERTS_DIR}"

    # Define the root certificate and key names
    ROOT_CERT="${CERTS_DIR}/root-cert.pem"
    ROOT_KEY="${CERTS_DIR}/root-key.pem"
    CA_CHAIN="${CERTS_DIR}/cert-chain.pem"
    OPENSSL_CONFIG="${CERTS_DIR}/openssl.cnf"

    if [ ! -f "${ROOT_CERT}" ] || [ ! -f "${ROOT_KEY}" ]; then
        echo "Generating root CA certificates..."

        cat > "${OPENSSL_CONFIG}" <<EOF
[ req ]
encrypt_key = no
prompt = no
utf8 = yes
default_md = sha256
default_bits = 4096
req_extensions = req_ext
x509_extensions = req_ext
distinguished_name = req_dn

[ req_ext ]
subjectKeyIdentifier = hash
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, nonRepudiation, keyEncipherment, keyCertSign

[ req_dn ]
O = Istio
CN = Root CA
EOF

        openssl genrsa -out "${ROOT_KEY}" 4096
        openssl req -x509 -new -nodes -key "${ROOT_KEY}" -sha256 -days 3650 -subj "/O=Istio/CN=Root CA" -out "${ROOT_CERT}" -config "${OPENSSL_CONFIG}"
    else
        echo "Root CA certificates already exist. Using existing certificates."
    fi

    cp "${ROOT_CERT}" "${CA_CHAIN}"

    # Define directory for the cluster's certificates within CERTS_DIR
    CLUSTER_CERTS_DIR="${CERTS_DIR}/${context}"
    mkdir -p "${CLUSTER_CERTS_DIR}"

    # Define file names for the cluster's certificates
    CA_CERT="${CLUSTER_CERTS_DIR}/ca-cert.pem"
    CA_KEY="${CLUSTER_CERTS_DIR}/ca-key.pem"

    echo "Generating CA certificate and key for context: ${context}"
    openssl req -new -sha256 -nodes -newkey rsa:4096 -subj "/O=Istio/CN=Istio CA ${context}" -keyout "${CA_KEY}" -out "${CLUSTER_CERTS_DIR}/${context}-csr.pem"
    openssl x509 -req -days 3650 -CA "${ROOT_CERT}" -CAkey "${ROOT_KEY}" -set_serial 1 -in "${CLUSTER_CERTS_DIR}/${context}-csr.pem" -out "${CA_CERT}" -extfile "${OPENSSL_CONFIG}" -extensions req_ext


    cat "${CA_CERT}" "${ROOT_CERT}" > "${CA_CHAIN}"

    echo "Applying certificates to ${context}..."
    kubectl --context="${context}" create secret generic cacerts -n istio-system \
      --from-file=ca-cert.pem="${CA_CERT}" \
      --from-file=ca-key.pem="${CA_KEY}" \
      --from-file=root-cert.pem="${ROOT_CERT}" \
      --from-file=cert-chain.pem="${CA_CHAIN}" \
      --dry-run=client -o yaml | kubectl --context="${context}" apply -f -

    echo "Certificates applied to cluster: ${context}"
}

