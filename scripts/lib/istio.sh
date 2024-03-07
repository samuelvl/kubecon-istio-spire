#!/bin/sh
set -u -o errexit -x

. "./scripts/lib/spire.sh"
. "./scripts/lib/istio-certs.sh"
. "./scripts/lib/istio-apps.sh"
. "./scripts/lib/istio-observability.sh"
. "./scripts/lib/kind-utils.sh"

export ISTIO_GW_BASE_PORT_HTTP=31080
export ISTIO_GW_BASE_PORT_HTTPS=31443

BIN_DIR=${BIN_DIR:-.}
ISTIO_CLI="${BIN_DIR}/istioctl"
ISTIO_VERSION="1.20.3"
ISTIO_NAMESPACE="istio-system"
ISTIO_GW_NAMESPACE="istio-gateways"
ISTIO_MESHID="mesh1"
ISTIO_NETWORK="network1"

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
  istio_certs_generate_root_ca

  cluster_counter=0
  for context in ${clusters_contexts}; do
    echo "Creating istio-sytsem namespace"
    kubectl create --context="${context}" namespace "${ISTIO_NAMESPACE}" || true

    echo "Generate and apply istio certificates"
    istio_certs_generate_intermediate_ca "${context}" "${ISTIO_NAMESPACE}"

    echo "Installing Istio in ${context} cluster"
    spire_clusters=$(kind_utils_remote_clusters "${context}" "${clusters_contexts}")
    istio_install_control_plane "${context}" "${spire_clusters}"

    # Install the Istio N/S gateway in the first cluster only
    if [ "${cluster_counter}" = "0" ]; then
      istio_install_ns_gateway "${context}" "${ISTIO_GW_NAMESPACE}" "${cluster_counter}"
      istio_certs_generate_cert "${context}" "${ISTIO_GW_NAMESPACE}" "bookinfo.kubecon"
    fi

    if [ "${observability}" = "true" ]; then
      echo "Installing Prometheus in ${context} cluster"
      istio_observability_prometheus_install "${context}" "${ISTIO_OBSERVABILITY_NAMESPACE}"
    fi

    echo "Installing Istio apps in ${context} cluster"
    istio_apps_bookinfo "${context}" "${cluster_counter}"

    cluster_counter=$((cluster_counter + 1))
  done
); }

istio_install_multicluster() { (
  clusters_contexts="${1}"
  observability="${2}"
  all_clusters=$(kind_utils_all_clusters "${clusters_contexts}")

  istio_install "${clusters_contexts}" "${observability}"

  cluster_counter=0
  for context in ${clusters_contexts}; do
    remote_clusters=$(kind_utils_remote_clusters "${context}" "${clusters_contexts}")

    # Enable multi-cluster discovery
    istio_enable_endpoint_discovery "${context}" "${remote_clusters}"

    # Deploy Thanos and Kiali only on the first cluster
    if [ "${observability}" = "true" ] && [ "${cluster_counter}" = "0" ]; then
      istio_observability_thanos_install "${context}" "${ISTIO_OBSERVABILITY_NAMESPACE}" "${all_clusters}"
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
  namespace="${2}"
  cluster_counter="${3}"
  cluster=$(kind_utils_cluster_name "${context}")

  kubectl create --context="${context}" namespace "${namespace}" || true
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
        namespace: ${namespace}
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

istio_api_server() { (
  context="${1}"

  # Dynamically get the API server IP address for the current context using docker inspect
  cluster=$(kind_utils_cluster_name "${context}")
  istio_node_container=$(kind_utils_node_name "${cluster}")
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
