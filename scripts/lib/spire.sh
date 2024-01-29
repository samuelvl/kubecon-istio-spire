#!/bin/sh
set -o nounset

SPIRE_NAMESPACE="spire"

spire_install() {
    context="${1}"
    kubectl apply --context="${context}" -n "${SPIRE_NAMESPACE}" \
        -f https://raw.githubusercontent.com/istio/istio/release-1.19/samples/security/spire/spire-quickstart.yaml
}

"$@"
