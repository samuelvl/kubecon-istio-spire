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
ISTIO_MESHID="mesh1"
ISTIO_NETWORK="network1"
ISTIO_CERTS_DIR="_output/certs"
ISTIO_ROOT_CA_CERT="${ISTIO_CERTS_DIR}/root-cert.pem"
ISTIO_ROOT_CA_KEY="${ISTIO_CERTS_DIR}/root-key.pem"
ISTIO_CA_CHAIN="${ISTIO_CERTS_DIR}/cert-chain.pem"
ISTIO_OPENSSL_CONFIG="${ISTIO_CERTS_DIR}/openssl.cnf"

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
  clusters_contexts="${1}"

  istio_install_cli
  istio_generate_root_ca

  cluster_counter=0
  for context in ${clusters_contexts}; do
    echo "Creating istio-sytsem namespace"
    kubectl create --context="${context}" namespace "${ISTIO_NAMESPACE}" || true

    echo "Generate and apply istio certificates"
    istio_generate_cluster_certificate "${context}"

    echo "Installing Istio in ${context} cluster"
    istio_install_control_plane "${context}"
    istio_install_gateway "${cluster_counter}" "${context}"

    echo "Installing Istio apps in ${context} cluster"
    helloworld_version="v$((cluster_counter + 1))"
    istio_deploy_app_helloworld "${context}" ${ISTIO_APPS_NAMESPACE} ${helloworld_version}
    istio_deploy_app_sleep "${context}" ${ISTIO_APPS_NAMESPACE}

    cluster_counter=$((cluster_counter + 1))
  done
}

istio_install_multicluster() {
  clusters_contexts="${1}"

  istio_install "${clusters_contexts}"

  for current_context in ${clusters_contexts}; do
    for remote_context in ${clusters_contexts}; do
      if [ "${current_context}" != "${remote_context}" ]; then
        echo "Creating remote secret from ${current_context} and applying it to ${remote_context}"
        istio_enable_endpoint_discovery "${current_context}" "${remote_context}"
      fi
    done
  done
}

istio_install_control_plane() {
  context="${1}"

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

istio_api_server() {
  context="${1}"

  # Adjust the context name to match the container naming convention
  istio_node_container=$(echo "${context}" | sed 's/^kind-//')-control-plane

  # Dynamically get the API server IP address for the current context using docker inspect
  istio_api_server_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${istio_node_container}")

  # Construct the API server address using the container IP and the standard API server port (6443)
  echo "https://${istio_api_server_ip}:6443"
}

istio_enable_endpoint_discovery() {
  context="${1}"
  remote_context="${2}"
  istio_api_server="$(istio_api_server "${context}")"

  ${ISTIO_CLI} create-remote-secret \
    --context="${current_context}" \
    --name="${current_context}" \
    --server="${istio_api_server}" \
    --namespace="${ISTIO_NAMESPACE}" |
    kubectl apply -f - --context="${remote_context}"
}

istio_generate_root_ca() {
  # Create the certs directory
  mkdir -p "${ISTIO_CERTS_DIR}"

  echo "Generating root CA certificates..."

  cat >"${ISTIO_OPENSSL_CONFIG}" <<EOF

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

  openssl genrsa -out "${ISTIO_ROOT_CA_KEY}" 4096
  openssl req \
    -x509 \
    -new \
    -nodes \
    -key "${ISTIO_ROOT_CA_KEY}" \
    -sha256 \
    -days 3650 \
    -subj "/O=Istio/CN=Root CA" \
    -out "${ISTIO_ROOT_CA_CERT}" \
    -config "${ISTIO_OPENSSL_CONFIG}"

  cat "${ISTIO_ROOT_CA_CERT}" >"${ISTIO_CA_CHAIN}"
}

istio_generate_cluster_certificate() {
  context="${1}"

  # Define directory for the cluster's certificates within ISTIO_CERTS_DIR
  cluster_certs_dir="${ISTIO_CERTS_DIR}/${context}"
  mkdir -p "${cluster_certs_dir}"

  # Define file names for the cluster's certificates
  cluster_ca_cert="${cluster_certs_dir}/ca-cert.pem"
  cluster_ca_key="${cluster_certs_dir}/ca-key.pem"
  cluster_cert_csr="${cluster_certs_dir}/csr.pem"
  cluster_ca_chain="${cluster_certs_dir}/cert-chain.pem"

  echo "Generating CA certificate and key for context: ${context}"
  openssl req \
    -new \
    -sha256 \
    -nodes \
    -newkey rsa:4096 \
    -subj "/O=Istio/CN=Istio CA ${context}" \
    -keyout "${cluster_ca_key}" \
    -out "${cluster_cert_csr}"

  openssl x509 \
    -req \
    -days 3650 \
    -CA "${ISTIO_ROOT_CA_CERT}" \
    -CAkey "${ISTIO_ROOT_CA_KEY}" \
    -set_serial 1 \
    -in "${cluster_cert_csr}" \
    -out "${cluster_ca_cert}" \
    -extfile "${ISTIO_OPENSSL_CONFIG}" \
    -extensions req_ext

  cat "${ISTIO_ROOT_CA_CERT}" "${cluster_ca_cert}" >"${cluster_ca_chain}"
  cat "${cluster_ca_cert}" >>"${ISTIO_CA_CHAIN}"

  echo "Applying certificates to ${context}..."
  kubectl --context="${context}" create secret generic cacerts -n "${ISTIO_NAMESPACE}" \
    --from-file=ca-cert.pem="${cluster_ca_cert}" \
    --from-file=ca-key.pem="${cluster_ca_key}" \
    --from-file=root-cert.pem="${ISTIO_ROOT_CA_CERT}" \
    --from-file=cert-chain.pem="${cluster_ca_chain}" \
    --dry-run=client -o yaml | kubectl --context="${context}" apply -f -
}
