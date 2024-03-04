#!/bin/sh
set -u -o errexit -x

. "./scripts/lib/spire.sh"
. "./scripts/lib/istio-observability.sh"
. "./scripts/lib/kind-utils.sh"

export ISTIO_GW_BASE_PORT_HTTP=31080
export ISTIO_GW_BASE_PORT_HTTPS=31443

BIN_DIR=${BIN_DIR:-.}
ISTIO_CLI="${BIN_DIR}/istioctl"
ISTIO_VERSION="1.20.3"
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
ISTIO_PRODUCTPAGE_APP_DIR=scripts/manifests/istio/productpage
ISTIO_PRODUCTPAGE_APP_NAMESPACE=bookinfo

istio_install_cli() { (
  if [ -f "${ISTIO_CLI}" ]; then
    echo "${ISTIO_CLI} already exists"
    return
  fi

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
); }

istio_install() { (
  clusters_contexts="${1}"
  observability="${2}"

  istio_install_cli
  istio_generate_root_ca

  cluster_counter=0
  for context in ${clusters_contexts}; do
    echo "Creating istio-sytsem namespace"
    kubectl create --context="${context}" namespace "${ISTIO_NAMESPACE}" || true

    echo "Generate and apply istio certificates"
    istio_generate_cluster_certificate "${context}"

    echo "Installing Istio in ${context} cluster"
    spire_clusters=$(kind_utils_remote_clusters "${context}" "${clusters_contexts}")
    istio_install_control_plane "${context}" "${spire_clusters}"

    if [ "${cluster_counter}" -eq 0 ]; then
      istio_install_ns_gateway "${cluster_counter}" "${context}"
    fi

    echo "Installing Istio apps in ${context} cluster"
    helloworld_version="v$((cluster_counter + 1))"
    istio_deploy_app_helloworld "${context}" "${ISTIO_APPS_NAMESPACE}" "${helloworld_version}"
    istio_deploy_app_sleep "${context}" "${ISTIO_APPS_NAMESPACE}"
    istio_deploy_app_productpage_frontend "${context}" "${cluster_counter}" "${ISTIO_PRODUCTPAGE_APP_NAMESPACE}"
    istio_deploy_app_productpage_backend "${context}" "${cluster_counter}" "${ISTIO_PRODUCTPAGE_APP_NAMESPACE}"
    istio_deploy_routing "${context}" "${cluster_counter}" "${ISTIO_PRODUCTPAGE_APP_NAMESPACE}"

    if [ "${observability}" = "true" ]; then
      echo "Installing Prometheus in ${context} cluster"
      istio_observability_prometheus_install "${context}" "${ISTIO_OBSERVABILITY_NAMESPACE}"
    fi

    cluster_counter=$((cluster_counter + 1))
  done
); }

istio_install_multicluster() { (
  clusters_contexts="${1}"
  observability="${2}"

  istio_install "${clusters_contexts}" "${observability}"

  cluster_counter=0
  for context in ${clusters_contexts}; do
    remote_clusters=$(kind_utils_remote_clusters "${context}" "${clusters_contexts}")

    # Enable multi-cluster discovery
    istio_enable_endpoint_discovery "${context}" "${remote_clusters}"

    # Deploy Thanos and Kiali only on the first cluster
    if [ "${observability}" = "true" ] && [ "${cluster_counter}" = "0" ]; then
      istio_observability_thanos_install "${context}" "${ISTIO_OBSERVABILITY_NAMESPACE}" "${remote_clusters}"
      istio_observability_kiali_install "${context}" "${cluster_counter}" "${ISTIO_OBSERVABILITY_NAMESPACE}"
    fi

    cluster_counter=$((cluster_counter + 1))
  done
); }

istio_install_control_plane() { (
  context="${1}"
  spire_clusters="${2}"
  cluster=$(kind_utils_cluster_name "${context}")

  # Install Istio control plane
  cat <<EOF | tee /dev/tty | ${ISTIO_CLI} install --context "${context}" -y --verify -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: control-plane
  namespace: ${ISTIO_NAMESPACE}
spec:
  profile: minimal
  meshConfig:
    trustDomain: $(kind_utils_trust_domain "${cluster}")
    trustDomainAliases:
$(istio_mesh_config_spire_domains "${spire_clusters}" | sed 's/^/      /')
    defaultConfig:
      proxyMetadata:
        PROXY_CONFIG_XDS_AGENT: "true"
    accessLogFile: /dev/stdout
    outboundTrafficPolicy:
      mode: ALLOW_ANY
  components:
    pilot:
      k8s:
        env:
          - name: ISTIO_MULTIROOT_MESH
            value: "true"
          - name: AUTO_RELOAD_PLUGIN_CERTS
            value: "true"
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
    sidecarInjectorWebhook:
      templates:
        spire: |
          spec:
            containers:
            - name: istio-proxy
              volumeMounts:
              - name: workload-socket
                mountPath: /run/secrets/workload-spiffe-uds
                readOnly: true
            volumes:
              - name: workload-socket
                csi:
                  driver: "csi.spiffe.io"
                  readOnly: true
        spire-gw: |
          spec:
            containers:
            - name: istio-proxy
              volumeMounts:
              - name: workload-socket
                mountPath: /run/secrets/workload-spiffe-uds
                readOnly: true
            volumes:
              - name: workload-socket
                emptyDir: null
                csi:
                  driver: "csi.spiffe.io"
                  readOnly: true
            initContainers:
            - name: wait-for-spire-socket
              image: busybox:1.28
              volumeMounts:
                - name: workload-socket
                  mountPath: /run/secrets/workload-spiffe-uds
                  readOnly: true
              env:
                - name: CHECK_FILE
                  value: /run/secrets/workload-spiffe-uds/socket
              command:
                - sh
                - "-c"
                - |-
                  echo "\$(date -Iseconds)" Waiting for: \${CHECK_FILE}
                  while [[ ! -e \${CHECK_FILE} && ! -L \${CHECK_FILE} ]] ; do
                    echo "\$(date -Iseconds)" File does not exist: \${CHECK_FILE}
                    sleep 15
                  done
                  ls -l \${CHECK_FILE}
EOF
); }

istio_mesh_config_spire_domains() { (
  spire_clusters="${1}"
  for spire_cluster in ${spire_clusters}; do
    echo "- $(kind_utils_trust_domain "${spire_cluster}")"
  done
); }

istio_install_ns_gateway() { (
  context="${1}"
  cluster_counter="${2}"
  cluster=$(kind_utils_cluster_name "${context}")

  kubectl create --context="${context}" namespace "${ISTIO_GW_NAMESPACE}" || true
  cat <<EOF | tee /dev/tty | ${ISTIO_CLI} install --context "${context}" --force -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: istio-ingressgateway
  namespace: ${ISTIO_NAMESPACE}
spec:
  profile: empty
  meshConfig:
    trustDomain: $(kind_utils_trust_domain "${cluster}")
    accessLogFile: /dev/stdout
  components:
    ingressGateways:
      - name: istio-ingressgateway
        namespace: ${ISTIO_GW_NAMESPACE}
        enabled: true
        label:
          istio: ingressgateway
          traffic: north-south
          spiffe.io/spire-managed-identity: "true"
        k8s:
          env:
            - name: ISTIO_META_ROUTER_MODE
              value: sni-dnat
          service:
            type: NodePort
            selector:
              app: istio-ingressgateway
              istio: ingressgateway
              traffic: north-south
            ports:
              - name: http2
                port: 80
                targetPort: 8080
                nodePort: $(kind_utils_unique_port "${cluster_counter}" "${ISTIO_GW_BASE_PORT_HTTP}")
              - name: https
                port: 443
                targetPort: 8443
                nodePort: $(kind_utils_unique_port "${cluster_counter}" "${ISTIO_GW_BASE_PORT_HTTPS}")
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
        injectionTemplate: gateway,spire-gw
EOF
); }

istio_deploy_app_helloworld() { (
  context="${1}"
  namespace="${2}"
  version="${3}" # v1 or v2

  # Create namespace and label it for Istio sidecar injection
  kubectl create --context="${context}" namespace "${namespace}" || true

  # Deploy Helloworld app
  kubectl apply --context="${context}" -n "${namespace}" \
    -l app=helloworld -l version="${version}" -f scripts/manifests/istio/helloworld.yaml

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

  kubectl --context="${context}" -n "${namespace}" rollout status "deploy/helloworld-${version}"
); }

istio_deploy_app_sleep() { (
  context="${1}"
  namespace="${2}"

  # Create namespace and label it for Istio sidecar injection
  kubectl create --context="${context}" namespace "${namespace}" || true

  # Deploy Sleep app
  kubectl apply --context="${context}" -n "${namespace}" -f scripts/manifests/istio/sleep.yaml
  kubectl --context="${context}" -n "${namespace}" rollout status deploy/sleep
); }

istio_deploy_app_productpage_frontend() { (
  context="${1}"
  cluster_counter="${2}"
  namespace="${3}"

  # Create namespace and label it for Istio sidecar injection
  kubectl create --context="${context}" namespace "${namespace}" || true

  # Deploy Productpage MicroServices
  if [ "${cluster_counter}" -eq 0 ]; then
    kubectl apply --context="${context}" -n "${namespace}" -f ${ISTIO_PRODUCTPAGE_APP_DIR}/productpage.yaml
    kubectl apply --context="${context}" -n "${namespace}" -f ${ISTIO_PRODUCTPAGE_APP_DIR}/reviews-v3.yaml
    kubectl apply --context="${context}" -n "${namespace}" -f ${ISTIO_PRODUCTPAGE_APP_DIR}/ratings.yaml
    kubectl apply --context="${context}" -n "${namespace}" -f ${ISTIO_PRODUCTPAGE_APP_DIR}/details.yaml
    kubectl --context="${context}" -n "${namespace}" rollout status deploy/productpage-v1
    kubectl --context="${context}" -n "${namespace}" rollout status deploy/reviews-v3
    kubectl --context="${context}" -n "${namespace}" rollout status deploy/ratings-v1
    kubectl --context="${context}" -n "${namespace}" rollout status deploy/details-v1
  fi

); }

istio_deploy_app_productpage_backend() { (
  context="${1}"
  cluster_counter="${2}"
  namespace="${3}"

  # Create namespace and label it for Istio sidecar injection
  kubectl create --context="${context}" namespace "${namespace}" || true

  # Deploy Productage MicroServices
  if [ "${cluster_counter}" -ne 0 ]; then
    kubectl apply --context="${context}" -n "${namespace}" -f ${ISTIO_PRODUCTPAGE_APP_DIR}/reviews-v1-v2.yaml
    kubectl apply --context="${context}" -n "${namespace}" -f ${ISTIO_PRODUCTPAGE_APP_DIR}/details.yaml
    kubectl --context="${context}" -n "${namespace}" rollout status deploy/reviews-v1
    kubectl --context="${context}" -n "${namespace}" rollout status deploy/reviews-v2
    kubectl --context="${context}" -n "${namespace}" rollout status deploy/details-v1
  fi

); }

istio_deploy_routing() { (
  context="${1}"
  cluster_counter="${2}"
  namespace="${3}"

  # Deploy Istio Routing
  if [ "${cluster_counter}" -eq 0 ]; then
    kubectl apply --context="${context}" -n "${namespace}" -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/bookinfo/networking/bookinfo-gateway.yaml
  fi

); }

istio_api_server() { (
  context="${1}"

  # Adjust the context name to match the container naming convention
  istio_node_container=$(echo "${context}" | sed 's/^kind-//')-control-plane

  # Dynamically get the API server IP address for the current context using docker inspect
  istio_api_server_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${istio_node_container}")

  # Construct the API server address using the container IP and the standard API server port (6443)
  echo "https://${istio_api_server_ip}:6443"
); }

istio_enable_endpoint_discovery() { (
  context="${1}"
  remote_clusters="${2}"

  for remote_cluster in ${remote_clusters}; do
    remote_context=$(kind_utils_context_name "${remote_cluster}")
    remote_api_server="$(istio_api_server "${remote_context}")"

    ${ISTIO_CLI} create-remote-secret \
      --context="${remote_context}" \
      --name="${remote_context}" \
      --server="${remote_api_server}" \
      --namespace="${ISTIO_NAMESPACE}" |
      kubectl apply -f - --context="${context}"
  done
); }

istio_generate_root_ca() { (
  # Create the certs directory
  mkdir -p "${ISTIO_CERTS_DIR}"

  if [ -f "${ISTIO_ROOT_CA_CERT}" ]; then
    echo "Root CA already exists..."
    return
  fi

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
); }

istio_generate_cluster_certificate() { (
  context="${1}"

  # Define directory for the cluster's certificates within ISTIO_CERTS_DIR
  cluster_certs_dir="${ISTIO_CERTS_DIR}/${context}"
  mkdir -p "${cluster_certs_dir}"

  # Define file names for the cluster's certificates
  cluster_ca_cert="${cluster_certs_dir}/ca-cert.pem"
  cluster_ca_key="${cluster_certs_dir}/ca-key.pem"
  cluster_cert_csr="${cluster_certs_dir}/csr.pem"
  cluster_ca_chain="${cluster_certs_dir}/cert-chain.pem"

  if [ -f "${cluster_ca_cert}" ]; then
    echo "Certificate for cluster ${context} already exists..."
    return
  fi

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
); }
