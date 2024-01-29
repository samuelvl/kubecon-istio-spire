#!/bin/sh
set -o nounset

ISTIO_NAMESPACE="istio-system"

istio_install() {
    context="${1}"
    istio_install_control_plane "${context}"
    istio_install_gateway "${context}"
}

istio_install_control_plane() {
    context="${1}"
    kubectl create --context="${context}" namespace "${ISTIO_NAMESPACE}" || true
    cat <<EOF | istioctl install --context "${context}" -y --verify -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: control-plane
  namespace: ${ISTIO_NAMESPACE}
spec:
  profile: minimal
  meshConfig:
    accessLogFile: /dev/stdout
    outboundTrafficPolicy:
      mode: ALLOW_ANY
  values:
    global:
      defaultPodDisruptionBudget:
        enabled: false
    pilot:
      autoscaleEnabled: false
EOF
}

istio_install_gateway() {
    context="${1}"
    kubectl create --context="${context}" namespace "${ISTIO_NAMESPACE}" || true
    cat <<EOF | istioctl install --context "${context}" -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: istio-ingressgateway
  namespace: ${ISTIO_NAMESPACE}
spec:
  profile: empty
  meshConfig:
    accessLogFile: /dev/stdout
  components:
    ingressGateways:
      - name: istio-ingressgateway
        namespace: ${ISTIO_NAMESPACE}
        enabled: true
        label:
          istio: ingressgateway
          traffic: north-south
        k8s:
          service:
            type: NodePort
            selector:
              app: istio-ingressgateway
              istio: ingressgateway
              traffic: north-south
            ports:
              - port: 80
                targetPort: 8080
                name: http2
                nodePort: 31080
              - port: 443
                targetPort: 8443
                name: https
                nodePort: 31443
              - port: 9000
                targetPort: 9000
                name: tcp
                nodePort: 31445
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
        injectionTemplate: gateway
EOF
}

"$@"
