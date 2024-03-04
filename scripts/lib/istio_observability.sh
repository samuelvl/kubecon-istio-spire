#!/bin/sh
set -u -o errexit -x

. "./scripts/lib/helm.sh"

BIN_DIR=${BIN_DIR:-.}
OBSERVABILITY_NAMESPACE="observability"
PROMETHEUS_MANIFESTS_DIR="scripts/manifests/prometheus"
KIALI_MANIFESTS_DIR="scripts/manifests/kiali"
THANOS_SERVICE="thanos-query-frontend"
THANOS_PORT=9090
THANOS_SIDECAR_GRPC_PORT=10901
THANOS_SIDECAR_GRPC_NODEPORT=30901

istio_observability_deploy_stack () { (
  clusters_contexts="${1}"

  cluster_counter=0
  first_context=""

  for context in ${clusters_contexts}; do
    if [ "${cluster_counter}" -eq 0 ]; then
      # Save the first context to use later
      first_context="${context}"
    fi

    echo "Creating observability namespace"
    kubectl create --context="${context}" namespace "${OBSERVABILITY_NAMESPACE}" || true

    echo "Deploy Prometheus server ${context} context"
    istio_observability_prometheus_server_deploy "${context}"
    istio_observability_prometheus_scrape_config "${context}"

    cluster_counter=$((cluster_counter + 1))
  done

  # After the loop, deploy Thanos and Kiali only for the first context
  if [ -n "${first_context}" ]; then
    echo "Deploy Thanos server ${first_context} context"
    istio_observability_thanos_server_deploy "${first_context}" "${clusters_contexts}"

    echo "Deploy Kiali server ${first_context} context"
    istio_observability_kiali_server_deploy "${first_context}"
  fi

); }

istio_observability_prometheus_server_deploy () { (
  context="${1}"

  ${HELM_CLI} repo add bitnami https://charts.bitnami.com/bitnami 
  ${HELM_CLI} repo update bitnami

  helm upgrade --install --kube-context="${context}" prometheus \
  --set prometheus.externalLabels.cluster=$(istio_observability_prometheus_cluster_name "${context}") \
  --namespace ${OBSERVABILITY_NAMESPACE} \
  --values "$(istio_observability_prometheus_helm_values "${context}")" \
  bitnami/kube-prometheus

); }

istio_observability_thanos_server_deploy () { (
  context="${1}"

  helm upgrade --install --kube-context="${context}" thanos bitnami/thanos  --namespace ${OBSERVABILITY_NAMESPACE} \
  --values "$(istio_observability_thanos_helm_values)"

); }

istio_observability_kiali_server_deploy () { (
  context="${1}"

  ${HELM_CLI} repo add kiali https://kiali.org/helm-charts

  #Apply Kiali Config

  helm upgrade --install --kube-context="${context}" kiali-server kiali/kiali-server \
    --namespace ${OBSERVABILITY_NAMESPACE} 

  kubectl --context "${context}" apply -f ${KIALI_MANIFESTS_DIR}/*

); }

istio_observability_prometheus_helm_values() { (

  prometheus_values_file_tmp=$(mktemp -q)
  cat >"${prometheus_values_file_tmp}" <<-EOF
prometheus:
  thanos:
    create: true
    service:
      type: NodePort
      ports:
        grpc: ${THANOS_SIDECAR_GRPC_PORT}
      nodePorts:
        grpc: ${THANOS_SIDECAR_GRPC_NODEPORT}
EOF

  echo "${prometheus_values_file_tmp}"

); }

istio_observability_prometheus_scrape_config() { (
  cluster="${1}"

  prometheus_additional_scrape_config="${PROMETHEUS_MANIFESTS_DIR}/prometheus-additional-scrape-configs.yml"

  kubectl --context="${cluster}" apply -f ${prometheus_additional_scrape_config}

); }

istio_observability_thanos_helm_values() { (
  # Start building the querier stores configuration string
  stores_config="query:
  stores:"

  # Iterate over each context in the list
  for context in ${clusters_contexts}; do
    kind_domain=$(istio_observability_kind_cluster_domain "${context}")
    # Append the trust domain and node port for each cluster to the stores configuration
    stores_config="${stores_config}
    - ${kind_domain}:${THANOS_SIDECAR_GRPC_NODEPORT}"
  done

  # Write the complete configuration to the temporary file
  thanos_values_file_tmp=$(mktemp -q)
  cat >"${thanos_values_file_tmp}" <<-EOF
${stores_config}
EOF

  echo "${thanos_values_file_tmp}"

); }

istio_observability_prometheus_cluster_name() { (
  context="${1}"
  echo "${context}" | sed -e "s/^kind-//"
); }

istio_observability_thanos_get_nodeport() {
  cluster="${1}"
  nodePort=$(kubectl --context="${cluster}" get svc -n ${OBSERVABILITY_NAMESPACE} prometheus-kube-prometheus-prometheus-thanos -o=jsonpath='{.spec.ports[?(@.name=="grpc")].nodePort}')
  
  echo $nodePort
}

istio_observability_kind_cluster_domain() { (
  cluster="${1}"
  cluster_domain="${cluster#kind-}-control-plane.kind"
  
  echo "$cluster_domain"
); }
