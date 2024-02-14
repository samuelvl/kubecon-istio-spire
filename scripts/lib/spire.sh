#!/bin/sh
set -u -o errexit -x

SPIRE_NAMESPACE="spire"
SPIRE_MANIFESTS_URL="https://raw.githubusercontent.com/spiffe/spire-tutorials/main/k8s/quickstart"

spire_install() {
  clusters_contexts="${1}"
  for context in ${clusters_contexts}; do
    spire_install_server "${context}"
    spire_install_agent "${context}"
    spire_wait_for_node_attestation "${context}"
  done
}

spire_install_server() {
  context="${1}"
  kubectl create --context="${context}" namespace "${SPIRE_NAMESPACE}" || true
  kubectl apply --context="${context}" -n "${SPIRE_NAMESPACE}" -f "${SPIRE_MANIFESTS_URL}/server-account.yaml"
  kubectl apply --context="${context}" -n "${SPIRE_NAMESPACE}" -f "${SPIRE_MANIFESTS_URL}/server-cluster-role.yaml"
  kubectl apply --context="${context}" -n "${SPIRE_NAMESPACE}" -f "${SPIRE_MANIFESTS_URL}/server-configmap.yaml"
  kubectl apply --context="${context}" -n "${SPIRE_NAMESPACE}" -f "${SPIRE_MANIFESTS_URL}/spire-bundle-configmap.yaml"
  kubectl apply --context="${context}" -n "${SPIRE_NAMESPACE}" -f "${SPIRE_MANIFESTS_URL}/server-service.yaml"
  kubectl apply --context="${context}" -n "${SPIRE_NAMESPACE}" -f "${SPIRE_MANIFESTS_URL}/server-statefulset.yaml"
}

spire_install_agent() {
  context="${1}"
  kubectl create --context="${context}" namespace "${SPIRE_NAMESPACE}" || true
  kubectl apply --context="${context}" -n "${SPIRE_NAMESPACE}" -f "${SPIRE_MANIFESTS_URL}/agent-account.yaml"
  kubectl apply --context="${context}" -n "${SPIRE_NAMESPACE}" -f "${SPIRE_MANIFESTS_URL}/agent-cluster-role.yaml"
  kubectl apply --context="${context}" -n "${SPIRE_NAMESPACE}" -f "${SPIRE_MANIFESTS_URL}/agent-configmap.yaml"
  kubectl apply --context="${context}" -n "${SPIRE_NAMESPACE}" -f "${SPIRE_MANIFESTS_URL}/agent-daemonset.yaml"
}

spire_wait_for_node_attestation() {
  context="${1}"
  for _ in $(seq 120); do
    if (kubectl logs --context="${context}" -n "${SPIRE_NAMESPACE}" --tail=-1 pod/spire-server-0 |
      grep -e ".*Agent attestation request completed.*k8s_sat.*"); then break; fi
    sleep 5
  done
}
