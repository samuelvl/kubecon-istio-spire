#!/bin/sh
set -u -o errexit -x

. "./scripts/lib/helm.sh"
. "./scripts/lib/kind-utils.sh"

export ISTIO_OBSERVABILITY_NAMESPACE="istio-observability"
export KIALI_BASE_PORT_HTTP=30201
export THANOS_STORE_BASE_PORT_GRPC=30901

istio_observability_prometheus_install() { (
  context="${1}"
  namespace="${2}"
  cluster=$(kind_utils_cluster_name "${context}")

  kubectl create --context="${context}" namespace "${namespace}" || true

  ${HELM_CLI} repo add bitnami https://charts.bitnami.com/bitnami
  ${HELM_CLI} repo update bitnami

  ${HELM_CLI} upgrade \
    --install prometheus bitnami/kube-prometheus \
    --namespace "${namespace}" \
    --kube-context "${context}" \
    --set prometheus.externalLabels.cluster="${cluster}" \
    --values "$(istio_observability_prometheus_helm_values)" \
    --wait \
    --cleanup-on-fail=false

  kubectl apply --context="${context}" -n "${namespace}" \
    -f scripts/manifests/prometheus/prometheus-additional-scrape-configs.yaml
); }

istio_observability_prometheus_helm_values() { (
  values_file_tmp=$(mktemp -q)
  cat >"${values_file_tmp}" <<-EOF
prometheus:
  thanos:
    create: true
    service:
      type: NodePort
      nodePorts:
        grpc: ${THANOS_STORE_BASE_PORT_GRPC}
alertmanager:
  enabled: false
EOF
  echo "${values_file_tmp}"
); }

istio_observability_thanos_install() { (
  context="${1}"
  namespace="${2}"
  remote_clusters="${3}"

  kubectl create --context="${context}" namespace "${namespace}" || true

  ${HELM_CLI} repo add bitnami https://charts.bitnami.com/bitnami
  ${HELM_CLI} repo update bitnami

  helm upgrade \
    --install thanos bitnami/thanos \
    --namespace "${namespace}" \
    --kube-context "${context}" \
    --values "$(istio_observability_thanos_helm_values "${remote_clusters}")" \
    --wait \
    --cleanup-on-fail=false
); }

istio_observability_thanos_helm_values() { (
  remote_clusters="${1}"
  values_file_tmp=$(mktemp -q)
  cat >"${values_file_tmp}" <<-EOF
query:
  stores:
$({
    for remote_cluster in ${remote_clusters}; do
      thanos_remote_addr="$(kind_utils_node_host "${remote_cluster}")"
      echo "    - ${thanos_remote_addr}:${THANOS_STORE_BASE_PORT_GRPC}"
    done
  })
EOF
  echo "${values_file_tmp}"
); }

istio_observability_kiali_install() { (
  context="${1}"
  cluster_counter="${2}"
  namespace="${3}"

  kubectl create --context="${context}" namespace "${namespace}" || true

  ${HELM_CLI} repo add kiali https://kiali.org/helm-charts
  ${HELM_CLI} repo update kiali

  helm upgrade \
    --install kiali-server kiali/kiali-server \
    --namespace "${namespace}" \
    --kube-context "${context}" \
    --wait \
    --cleanup-on-fail=false

  kubectl apply --context="${context}" -n "${namespace}" -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: kiali-nodeport
spec:
  type: NodePort
  internalTrafficPolicy: Cluster
  selector:
    app.kubernetes.io/instance: kiali
    app.kubernetes.io/name: kiali
  ports:
    - name: http
      nodePort: $(kind_utils_unique_port "${cluster_counter}" "${KIALI_BASE_PORT_HTTP}")
      port: 20001
      targetPort: 20001
EOF

  kubectl apply --context="${context}" -n "${namespace}" \
    -f scripts/manifests/kiali/cm.yaml

  kubectl --context="${context}" -n "${namespace}" rollout restart deploy/kiali
  kubectl --context="${context}" -n "${namespace}" rollout status deploy/kiali
); }
