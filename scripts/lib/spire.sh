#!/bin/sh
set -u -o errexit -x

. "./scripts/lib/helm.sh"

SPIFFE_HELM_CHART_VERSION="0.17.2"
SPIFFE_CRDS_HELM_CHART_VERSION="0.3.0"
SPIRE_SYSTEM_NAMESPACE="spire-system"
SPIRE_SERVER_SVC="spire-server"
SPIRE_SERVER_BASE_PORT_GRPC=30912
SPIRE_FEDERATION_BASE_PORT_GRPC=30000

spire_install() {
  contexts="${1}"
  cluster_counter=0
  helm_install_cli

  for context in ${contexts}; do
    remote_clusters=$(spire_remote_clusters "${context}" "${contexts}")
    spire_server_svc_create "${cluster_counter}" "${remote_clusters}"
    spire_helm_install "${context}" "${remote_clusters}"
    cluster_counter=$((cluster_counter + 1))
  done

  for context in ${contexts}; do
    remote_clusters=$(spire_remote_clusters "${context}" "${contexts}")
    spire_inject_bundle "${context}" "${remote_clusters}"
  done

}

spire_helm_install() {
  context="${1}"
  remote_clusters="${2}"
  cluster=$(spire_cluster_name "${context}")
  
  ${HELM_CLI} repo add spiffe "https://spiffe.github.io/helm-charts-hardened" --force-update
  ${HELM_CLI} repo update spiffe

  ${HELM_CLI} upgrade \
    --install spire-crds spiffe/spire-crds \
    --version "${SPIFFE_CRDS_HELM_CHART_VERSION}" \
    --namespace "${SPIRE_SYSTEM_NAMESPACE}" \
    --kube-context "${context}" \
    --namespace "${SPIRE_SYSTEM_NAMESPACE}" \
    --create-namespace \
    --wait \
    --cleanup-on-fail=false

  ${HELM_CLI} upgrade \
    --install spire spiffe/spire \
    --version "${SPIFFE_HELM_CHART_VERSION}" \
    --namespace "${SPIRE_SYSTEM_NAMESPACE}" \
    --kube-context "${context}" \
    --values "$(spire_helm_values "${cluster}" "${remote_clusters}")" \
    --namespace "${SPIRE_SYSTEM_NAMESPACE}" \
    --create-namespace \
    --wait \
    --cleanup-on-fail=false
}

spire_helm_values() {
  cluster="${1}"
  remote_clusters="${2}"

  values_file_tmp=$(mktemp -q "/tmp/spire-helm-values-${cluster}-XXXXXX.yaml")
  cat >"${values_file_tmp}" <<-EOF
global:
  spire:
    clusterName: ${cluster}
    trustDomain: $(spire_trust_domain "${cluster}")
    bundleConfigMap: spire-bundle-${cluster}
    ingressControllerType: other

spire-server:
  ca_subject:
    country: US
    common_name: ${cluster}.local
    organization: KubeCon
  federation:
    enabled: true
  service:
    type: NodePort
  controllerManager:
    identities:
      clusterSPIFFEIDs:
        istio:
          spiffeIDTemplate: "spiffe://{{ .TrustDomain }}/k8s/{{ .ClusterName }}/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}"
          federatesWith:
$(spire_helm_federated_spiffe_ids "${remote_clusters}")
      clusterFederatedTrustDomains:
$(spire_helm_federated_trust_domains "${remote_clusters}")

spire-agent:
  socketPath: /run/spire/agent-sockets-${cluster}/spire-agent.sock

spiffe-csi-driver:
  pluginName: ${cluster}.csi.spiffe.io
  agentSocketPath: /run/spire/agent-sockets-${cluster}/spire-agent.sock

spiffe-oidc-discovery-provider:
  enabled: false
EOF
  echo "${values_file_tmp}"
}

spire_helm_federated_spiffe_ids() {
  remote_clusters="${1}"
  for remote_cluster in ${remote_clusters}; do
    remote_cluster_domain=$(spire_trust_domain "${remote_cluster}")
    cat <<EOF
            - ${remote_cluster_domain}
EOF
  done
}

spire_helm_federated_trust_domains() {
  remote_clusters="${1}"
  for remote_cluster in ${remote_clusters}; do
    remote_cluster_domain=$(spire_trust_domain "${remote_cluster}")
    remote_spire_server_node_name=$(get_spire_server_node_name "${remote_cluster}")
    remote_spire_server_nodeport=$(get_spire_server_nodeport "${remote_cluster}")
    cat <<EOF
        ${remote_cluster}:
          bundleEndpointProfile:
            endpointSPIFFEID: spiffe://${remote_cluster_domain}/spire/server
            type: https_spiffe
          bundleEndpointURL: https://${remote_spire_server_node_name}:${remote_spire_server_nodeport}
          trustDomain: ${remote_cluster_domain}
EOF
  done
}

spire_remote_clusters() {
  context="${1}"
  remote_contexts="${2}"
  remote_clusters=""
  for remote_context in ${remote_contexts}; do
    if [ "${remote_context}" != "${context}" ]; then
      remote_clusters="${remote_clusters} $(spire_cluster_name "${remote_context}")"
    fi
  done
  echo "${remote_clusters}" | xargs
}

spire_cluster_name() {
  cluster="${1}"
  echo "${cluster}" | sed -e "s/^kind-//"
}

spire_trust_domain() {
  cluster="${1}"
  echo "${cluster}-domain.local"
}

get_spire_server_node_name() {
  cluster="${1}"
  remote_node="$(spire_cluster_name "${cluster}")"

  echo "${remote_node}-control-plane.kind"
}

get_spire_server_nodeport() {
  cluster="${1}"
  local targetPort=8443

  remote_nodeport=$(kubectl --context="kind-${cluster}"  -n "${SPIRE_SYSTEM_NAMESPACE}" get svc "${SPIRE_SERVER_SVC}" -o=jsonpath="{.spec.ports[?(@.port==${targetPort})].nodePort}")

  echo "${remote_nodeport}"
}

spire_server_svc_create() {
  index="${1}"
  cluster="${2}"

  kubectl create namespace "${SPIRE_SYSTEM_NAMESPACE}" --dry-run=client -o yaml | kubectl --context="kind-${cluster}" apply -f -

  kubectl apply --context="kind-${cluster}" -n "${SPIRE_SYSTEM_NAMESPACE}" -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: spire-server
  namespace: spire-system
  annotations:
    meta.helm.sh/release-name: spire
    meta.helm.sh/release-namespace: spire-system
  labels:
    app.kubernetes.io/managed-by: Helm
spec:
  internalTrafficPolicy: Cluster
  ports:
  - name: grpc
    nodePort: $(spire_unique_port "${index}" "${SPIRE_SERVER_BASE_PORT_GRPC}")
    port: 8081
    targetPort: grpc
  - name: federation
    nodePort: $(spire_unique_port "${index}" "${SPIRE_FEDERATION_BASE_PORT_GRPC}")
    port: 8443
    targetPort: federation
  selector:
    app.kubernetes.io/instance: spire
    app.kubernetes.io/name: server
  type: NodePort

EOF
  
}

spire_unique_port() {
  index="${1}"
  base_port="${2}"
                
  PORT_OFFSET=1000
  echo $((base_port + index * PORT_OFFSET))
}

spire_inject_bundle() {
  context="${1}"
  remote_context="${2}"

  bundle_output=$(kubectl --context="kind-${remote_context}" exec -n "${SPIRE_SYSTEM_NAMESPACE}" spire-server-0 -- spire-server bundle show -format spiffe)

  echo "$bundle_output" | kubectl --context="${context}" exec -i -n "${SPIRE_SYSTEM_NAMESPACE}" spire-server-0 -- spire-server bundle set -format spiffe -id spiffe://$(spire_trust_domain "${remote_context}")

}
