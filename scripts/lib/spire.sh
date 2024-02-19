#!/bin/sh
set -u -o errexit -x

. "./scripts/lib/helm.sh"

SPIFFE_HELM_CHART_VERSION="0.17.2"
SPIFFE_CRDS_HELM_CHART_VERSION="0.3.0"
SPIRE_SYSTEM_NAMESPACE="spire-system"
SPIRE_SERVER_NAMESPACE="spire-server"

spire_install() {
  contexts="${1}"
  helm_install_cli
  for context in ${contexts}; do
    remote_clusters=$(spire_remote_clusters "${context}" "${contexts}")
    spire_helm_install "${context}" "${remote_clusters}"
  done
}

spire_helm_install() {
  context="${1}"
  remote_clusters="${2}"
  cluster=$(spire_cluster_name "${context}")

  ${HELM_CLI} repo add spiffe "https://spiffe.github.io/helm-charts-hardened" --force-update
  ${HELM_CLI} repo update spiffe

  kubectl create namespace "${SPIRE_SYSTEM_NAMESPACE}" --dry-run=client -o yaml | kubectl --context="${context}" apply -f -
  kubectl create namespace "${SPIRE_SERVER_NAMESPACE}" --dry-run=client -o yaml | kubectl --context="${context}" apply -f -

  ${HELM_CLI} upgrade \
    --install spire-crds spiffe/spire-crds \
    --version "${SPIFFE_CRDS_HELM_CHART_VERSION}" \
    --namespace "${SPIRE_SYSTEM_NAMESPACE}" \
    --kube-context "${context}" \
    --wait \
    --cleanup-on-fail=false

  ${HELM_CLI} upgrade \
    --install spire spiffe/spire \
    --version "${SPIFFE_HELM_CHART_VERSION}" \
    --namespace "${SPIRE_SYSTEM_NAMESPACE}" \
    --kube-context "${context}" \
    --values "$(spire_helm_values "${cluster}" "${remote_clusters}")" \
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
  controllerManager:
    identities:
      clusterSPIFFEIDs:
        default:
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
    cat <<EOF
        ${remote_cluster}:
          bundleEndpointProfile:
            endpointSPIFFEID: spiffe://${remote_cluster_domain}/spire/server
            type: https_spiffe
          bundleEndpointURL: https://spire-server-federation.${remote_cluster_domain}
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
  echo "${remote_clusters}"
}

spire_cluster_name() {
  context="${1}"
  echo "${context}" | sed -e "s/^kind-//"
}

spire_trust_domain() {
  cluster="${1}"
  echo "${cluster}-domain.local"
}
