#!/bin/sh
set -u -o errexit -x

. "./scripts/lib/helm.sh"
. "./scripts/lib/istio.sh"

BIN_DIR=${BIN_DIR:-.}
OBSERVABILITY_NAMESPACE="observability"
PROMETHEUS_MANIFESTS_DIR=scripts/manifests/prometheus/
KIALI_MANIFESTS_DIR=scripts/manifests/kiali
THANOS_SERVICE=thanos-query-frontend
THANOS_PORT=9090

deploy_observability_stack () { (
  clusters_contexts="${1}"

  cluster_counter=0

  for context in ${clusters_contexts}; do
    echo "Creating observability namespace"
    kubectl create --context="${context}" namespace "${OBSERVABILITY_NAMESPACE}" || true

    echo "Deploy Prometheus server ${context} context"
    prometheus_scrape_config "${context}"
    prometheus_server_deploy "${context}"

    cluster_counter=$((cluster_counter + 1))
  done

  IFS=' ' read -r -a contexts_array <<< "${clusters_contexts}"

  if [ "${#contexts_array[@]}" -gt 0 ]; then
    echo "Deploy Thanos server ${contexts_array[0]} context"
    thanos_server_deploy "${contexts_array[0]}" "${clusters_contexts}"
  fi

  if [ "${#contexts_array[@]}" -gt 0 ]; then
    echo "Deploy Kiali server ${context} context"
    kiali_server_deploy "${contexts_array[0]}"
  fi

); }

prometheus_server_deploy () { (
  context="${1}"

  ${HELM_CLI} repo add bitnami https://charts.bitnami.com/bitnami 
  ${HELM_CLI} repo update bitnami

  helm upgrade --install --kube-context="${context}" prometheus \
  --set prometheus.externalLabels.cluster=$(prometheus_cluster_name "${context}") \
  --namespace ${OBSERVABILITY_NAMESPACE} \
  --values "$(prometheus_helm_values "${context}")" \
  bitnami/kube-prometheus

); }

thanos_server_deploy () { (
  context="${1}"

  helm upgrade --install --kube-context="${context}" thanos bitnami/thanos  --namespace ${OBSERVABILITY_NAMESPACE} \
  --values "$(thanos_helm_values)"

); }

kiali_server_deploy () { (
  context="${1}"

  ${HELM_CLI} repo add kiali https://kiali.org/helm-charts

  #Apply Kiali Config

  helm upgrade --install --kube-context="${context}" kiali-server kiali/kiali-server \
    --namespace ${OBSERVABILITY_NAMESPACE} 

  kubectl --context "${context}" apply -f ${KIALI_MANIFESTS_DIR}/*

); }

prometheus_helm_values() { (

  prometheus_values_file_tmp=$(mktemp -q)
  cat >"${prometheus_values_file_tmp}" <<-EOF
prometheus:
  thanos:
    create: true
    service:
      type: NodePort
EOF

  echo "${prometheus_values_file_tmp}"

); }

prometheus_scrape_config() { (
  cluster="${1}"

  prometheus_additional_scrape_config="${PROMETHEUS_MANIFESTS_DIR}/prometheus-additional-scrape-configs.yml"

  kubectl --context="${cluster}" apply -f ${prometheus_additional_scrape_config}

); }

thanos_helm_values() { (
  # Start building the querier stores configuration string
  stores_config="query:
  stores:"

  # Iterate over each context in the list
  for context in ${clusters_contexts}; do
    kind_domain=$(kind_cluster_domain "${context}")
    node_port=$(thanos_get_nodeport "${context}")
    # Append the trust domain and node port for each cluster to the stores configuration
    stores_config="${stores_config}
    - ${kind_domain}:${node_port}"
  done

  # Write the complete configuration to the temporary file
  thanos_values_file_tmp=$(mktemp -q)
  cat >"${thanos_values_file_tmp}" <<-EOF
${stores_config}
EOF

  echo "${thanos_values_file_tmp}"

); }

prometheus_cluster_name() { (
  context="${1}"
  echo "${context}" | sed -e "s/^kind-//"
); }

thanos_get_nodeport() {
  cluster="${1}"
  nodePort=$(kubectl --context="${cluster}" get svc -n ${OBSERVABILITY_NAMESPACE} prometheus-kube-prometheus-prometheus-thanos -o=jsonpath='{.spec.ports[?(@.name=="grpc")].nodePort}')
  
  echo $nodePort
}

kind_cluster_domain() { (
  cluster="${1}"
  cluster_domain="${cluster#kind-}-control-plane.kind"
  
  echo "$cluster_domain"
); }
