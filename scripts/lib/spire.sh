#!/bin/sh
set -u -o errexit -x

. "./scripts/lib/helm.sh"
. "./scripts/lib/kind-utils.sh"

export SPIRE_SERVER_BASE_PORT_BUNDLE=31300

SPIFFE_HELM_CHART_VERSION="0.17.2"
SPIFFE_CRDS_HELM_CHART_VERSION="0.3.0"
SPIRE_SYSTEM_NAMESPACE="spire-system"

spire_install() { (
  clusters_contexts="${1}"
  helm_install_cli

  cluster_counter=0
  for context in ${clusters_contexts}; do
    remote_clusters=$(kind_utils_remote_clusters "${context}" "${clusters_contexts}")
    spire_helm_install "${context}" "${cluster_counter}" "${remote_clusters}"
    cluster_counter=$((cluster_counter + 1))
  done

  for context in ${clusters_contexts}; do
    remote_clusters=$(kind_utils_remote_clusters "${context}" "${clusters_contexts}")
    spire_inject_bundle "${context}" "${remote_clusters}"
  done
); }

spire_helm_install() { (
  context="${1}"
  cluster_counter="${2}"
  remote_clusters="${3}"
  cluster=$(kind_utils_cluster_name "${context}")

  ${HELM_CLI} repo add spiffe "https://spiffe.github.io/helm-charts-hardened" --force-update
  ${HELM_CLI} repo update spiffe

  kubectl create namespace "${SPIRE_SYSTEM_NAMESPACE}" --dry-run=client -o yaml | kubectl --context="${context}" apply -f -

  spire_server_create_svc "${context}" "${cluster_counter}"

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
); }

spire_helm_values() { (
  cluster="${1}"
  remote_clusters="${2}"

  values_file_tmp=$(mktemp -q)
  cat >"${values_file_tmp}" <<-EOF
global:
  spire:
    clusterName: ${cluster}
    trustDomain: $(kind_utils_trust_domain "${cluster}")
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
          enabled: false
        oidc-discovery-provider:
          enabled: false
        test-keys:
          enabled: false
        istio:
          spiffeIDTemplate: spiffe://{{ .TrustDomain }}/ns/{{ .PodMeta.Namespace }}/sa/{{ .PodSpec.ServiceAccountName }}
          podSelector:
            matchLabels:
              spiffe.io/spire-managed-identity: "true"
          federatesWith:
$(spire_helm_federated_spiffe_ids "${remote_clusters}")
      clusterFederatedTrustDomains:
$(spire_helm_federated_trust_domains "${remote_clusters}")

spire-agent:
  sds:
    enabled: true
    defaultAllBundlesName: ROOTCA
    defaultBundleName: "null"
    defaultSvidName: default
  socketPath: /run/spire/agent-sockets/spire-agent.sock

spiffe-csi-driver:
  pluginName: csi.spiffe.io
  agentSocketPath: /run/spire/agent-sockets/spire-agent.sock

spiffe-oidc-discovery-provider:
  enabled: false
EOF
  echo "${values_file_tmp}"
); }

spire_helm_federated_spiffe_ids() { (
  remote_clusters="${1}"
  for remote_cluster in ${remote_clusters}; do
    remote_cluster_domain=$(kind_utils_trust_domain "${remote_cluster}")
    cat <<EOF
            - ${remote_cluster_domain}
EOF
  done
); }

spire_helm_federated_trust_domains() { (
  remote_clusters="${1}"
  for remote_cluster in ${remote_clusters}; do
    remote_cluster_domain=$(kind_utils_trust_domain "${remote_cluster}")
    cat <<EOF
        ${remote_cluster}:
          bundleEndpointURL: https://$(spire_server_federation_endpoint "${remote_cluster}")
          trustDomain: ${remote_cluster_domain}
          bundleEndpointProfile:
            type: https_spiffe
            endpointSPIFFEID: spiffe://${remote_cluster_domain}/spire/server
EOF
  done
); }

spire_server_federation_endpoint() { (
  cluster="${1}"
  federation_endpoint_addr="$(kind_utils_node_host "${cluster}")"
  federation_endpoint_port=$(spire_server_federation_endpoint_port "${cluster}")
  echo "${federation_endpoint_addr}:${federation_endpoint_port}"
); }

spire_server_federation_endpoint_port() { (
  cluster="${1}"
  docker port "$(kind_utils_node_name "${cluster}")" | grep "${SPIRE_SERVER_BASE_PORT_BUNDLE}" |
    sed -e "s#^\(.*\)0.0.0.0:\([0-9]*\)#\2#"
); }

spire_server_create_svc() { (
  context="${1}"
  cluster_counter="${2}"

  kubectl apply --context="${context}" -n "${SPIRE_SYSTEM_NAMESPACE}" -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: spire-server-nodeport
spec:
  type: NodePort
  internalTrafficPolicy: Cluster
  selector:
    app.kubernetes.io/instance: spire
    app.kubernetes.io/name: server
  ports:
    - name: federation
      nodePort: $(kind_utils_unique_port "${cluster_counter}" "${SPIRE_SERVER_BASE_PORT_BUNDLE}")
      port: 8443
      targetPort: federation
EOF
); }

spire_server_exec() { (
  context="${1}"
  command="${2}"
  # shellcheck disable=SC2086
  kubectl --context="${context}" exec -n "${SPIRE_SYSTEM_NAMESPACE}" -i spire-server-0 -- spire-server ${command}
); }

spire_get_bundle_pem() { (
  context="${1}"
  spire_server_exec "${context}" "bundle show -format pem"
); }

spire_inject_bundle() { (
  context="${1}"
  remote_clusters="${2}"

  for remote_cluster in ${remote_clusters}; do
    remote_context=$(kind_utils_context_name "${remote_cluster}")
    spire_server_exec "${remote_context}" "bundle show -format spiffe" |
      spire_server_exec "${context}" "bundle set -format spiffe -id spiffe://$(kind_utils_trust_domain "${remote_cluster}")"
  done
); }
