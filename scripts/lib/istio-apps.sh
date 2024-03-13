#!/bin/sh
set -u -o errexit -x

ISTIO_GW_NAMESPACE="istio-gateways"
ISTIO_APPS_BOOKINFO_NAMESPACE="bookinfo"
ISTIO_PRODUCTPAGE_APP_DIR="scripts/manifests/istio/productpage"
ISTIO_SLEEP_APP_DIR="scripts/manifests/istio/"

istio_apps_bookinfo() { (
  context="${1}"
  cluster_counter="${2}"

  if [ "${cluster_counter}" = "0" ]; then
    istio_apps_productpage_frontend "${context}" "${ISTIO_APPS_BOOKINFO_NAMESPACE}"
    istio_deploy_routing "${context}" "${ISTIO_APPS_BOOKINFO_NAMESPACE}"
    istio_deploy_jwt_policy "${context}" "${ISTIO_GW_NAMESPACE}"
    istio_apps_sleep "${context}" "${ISTIO_APPS_BOOKINFO_NAMESPACE}"
  else
    istio_apps_productpage_backend "${context}" "${ISTIO_APPS_BOOKINFO_NAMESPACE}"
    istio_deploy_auth_policy "${context}" "${ISTIO_APPS_BOOKINFO_NAMESPACE}"
  fi
); }

istio_apps_productpage_frontend() { (
  context="${1}"
  namespace="${2}"

  kubectl create --context="${context}" namespace "${namespace}" || true

  kubectl apply --context="${context}" -n "${namespace}" -f ${ISTIO_PRODUCTPAGE_APP_DIR}/productpage.yaml
  kubectl apply --context="${context}" -n "${namespace}" -f ${ISTIO_PRODUCTPAGE_APP_DIR}/details.yaml
  kubectl apply --context="${context}" -n "${namespace}" -f ${ISTIO_PRODUCTPAGE_APP_DIR}/reviews-ratings.svc

  kubectl --context="${context}" -n "${namespace}" rollout status deploy/productpage-v1
  kubectl --context="${context}" -n "${namespace}" rollout status deploy/details-v1
); }

istio_apps_productpage_backend() { (
  context="${1}"
  namespace="${2}"

  kubectl create --context="${context}" namespace "${namespace}" || true

  kubectl apply --context="${context}" -n "${namespace}" -f ${ISTIO_PRODUCTPAGE_APP_DIR}/reviews-v1-v2.yaml
  kubectl apply --context="${context}" -n "${namespace}" -f ${ISTIO_PRODUCTPAGE_APP_DIR}/details.yaml
  kubectl apply --context="${context}" -n "${namespace}" -f ${ISTIO_PRODUCTPAGE_APP_DIR}/ratings.yaml

  kubectl --context="${context}" -n "${namespace}" rollout status deploy/reviews-v1
  kubectl --context="${context}" -n "${namespace}" rollout status deploy/reviews-v2
  kubectl --context="${context}" -n "${namespace}" rollout status deploy/details-v1
  kubectl --context="${context}" -n "${namespace}" rollout status deploy/ratings-v1
); }

istio_apps_sleep() { (
  context="${1}"
  namespace="${2}"

  kubectl apply --context="${context}" -n "${namespace}" -f ${ISTIO_SLEEP_APP_DIR}/sleep.yaml

  kubectl --context="${context}" -n "${namespace}" rollout status deploy/sleep

); }

istio_deploy_routing() { (
  context="${1}"
  namespace="${2}"

  kubectl apply --context="${context}" -n "${ISTIO_GW_NAMESPACE}" -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: bookinfo
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 443
      name: https
      protocol: HTTPS
    tls:
      mode: SIMPLE
      credentialName: bookinfo-kubecon-tls
    hosts:
    - bookinfo.kubecon
EOF

  kubectl apply --context="${context}" -n "${namespace}" -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: bookinfo
spec:
  hosts:
  - "*"
  gateways:
  - ${ISTIO_GW_NAMESPACE}/bookinfo
  http:
  - match:
    - uri:
        exact: /productpage
    - uri:
        prefix: /static
    - uri:
        exact: /login
    - uri:
        exact: /logout
    - uri:
        prefix: /api/v1/products
    route:
    - destination:
        host: productpage
        port:
          number: 9080
EOF
); }

istio_deploy_jwt_policy() { (
  context="${1}"
  namespace="${2}"

  kubectl apply --context="${context}" -n "${namespace}" -f - <<EOF
apiVersion: security.istio.io/v1
kind: RequestAuthentication
metadata:
  name: jwt-example
spec:
  selector:
    matchLabels:
      app: istio-ingressgateway
  jwtRules:
    - issuer: testing@secure.istio.io
      jwksUri: https://raw.githubusercontent.com/istio/istio/release-1.20/security/tools/jwt/samples/jwks.json
EOF

  kubectl apply --context="${context}" -n "${namespace}" -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: require-jwt
spec:
  selector:
    matchLabels:
      app: istio-ingressgateway
  action: ALLOW
  rules:
    - from:
        - source:
            requestPrincipals:
              - testing@secure.istio.io/testing@secure.istio.io
EOF
); }

istio_deploy_auth_policy() { (
  context="${1}"
  namespace="${2}"

  kubectl apply --context="${context}" -n "${namespace}" -f - <<EOF
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: allow-productpage
  namespace: bookinfo
spec:
  action: ALLOW
  rules:
  - from:
    - source:
        principals:
        - istio-cluster-1.local/ns/bookinfo/sa/bookinfo-productpage
    to:
    - operation:
        methods:
        - GET
        paths:
        - /reviews/*
  selector:
    matchLabels:
      app: reviews
EOF
); }
