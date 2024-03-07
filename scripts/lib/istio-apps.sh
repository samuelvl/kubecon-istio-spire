#!/bin/sh
set -u -o errexit -x

export ISTIO_GW_NAMESPACE="istio-gateways"
export ISTIO_APPS_BOOKINFO_NAMESPACE="bookinfo"
export ISTIO_GW_CERTS_DIR="_output/certs/gateway"
export ISTIO_PRODUCTPAGE_APP_DIR="scripts/manifests/istio/productpage"

istio_apps_bookinfo() { (
  context="${1}"
  cluster_counter="${2}"

  if [ "${cluster_counter}" = "0" ]; then
    istio_apps_productpage_frontend "${context}" "${ISTIO_APPS_BOOKINFO_NAMESPACE}"
    istio_deploy_routing "${context}" "${ISTIO_APPS_BOOKINFO_NAMESPACE}"
    istio_deploy_jwt_policy "${context}" "${ISTIO_APPS_BOOKINFO_NAMESPACE}"
  else
    istio_apps_productpage_backend "${context}" "${ISTIO_APPS_BOOKINFO_NAMESPACE}"
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

istio_deploy_routing() { (
  context="${1}"
  namespace="${2}"

  gw_certs_dir=${ISTIO_GW_CERTS_DIR}
  ca_certs_dir=${ISTIO_CERTS_DIR}/${context}
  mkdir -p "${gw_certs_dir}"

  # Define file names for the gateway's certificates
  gw_cert="${gw_certs_dir}/kubecon.cluster.crt"
  gw_key="${gw_certs_dir}/kubecon.cluster.key"

  # Define file names for the intermediate CA's certificates
  ca_cert="${ca_certs_dir}/ca-cert.pem"
  ca_key="${ca_certs_dir}/ca-key.pem"

  # Create a private key for the gateway
  openssl genrsa -out "${gw_key}" 2048

  # Generate a certificate signing request (CSR) for the gateway
  openssl req -new -key "${gw_key}" \
    -out "${gw_certs_dir}/kubecon.cluster.csr" \
    -subj "/CN=kubecon.cluster/O=kubecon.cluster"

  # Sign the gateway's CSR with the intermediate CA's key to get the gateway's certificate
  openssl x509 -req -days 365 -in "${gw_certs_dir}/kubecon.cluster.csr" \
    -CA "${ca_cert}" -CAkey "${ca_key}" -CAcreateserial \
    -out "${gw_cert}"

  # Create a secret in Kubernetes with the generated key and certificate
  kubectl --context="${context}" create -n "${ISTIO_GW_NAMESPACE}" secret tls gw-credential \
    --key="${gw_key}" --cert="${gw_cert}"

  kubectl apply --context="${context}" -n "${ISTIO_GW_NAMESPACE}" -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: istio-gateway
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
      credentialName: gw-credential
    hosts:
    - kubecon.cluster
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
  - ${ISTIO_GW_NAMESPACE}/istio-gateway
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

  kubectl --context="${context}" apply -f - <<EOF
apiVersion: security.istio.io/v1                                                                
kind: RequestAuthentication
metadata:
  name: "jwt-example"
  namespace: "${namespace}"
spec:
  selector:
    matchLabels:
      app: productpage
  jwtRules:    
  - issuer: "testing@secure.istio.io"
    jwksUri: "https://raw.githubusercontent.com/istio/istio/release-1.20/security/tools/jwt/samples/jwks.json"
EOF

  kubectl --context="${context}" apply -f - <<EOF    
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: require-jwt
  namespace: "${namespace}"
spec:
  selector:
    matchLabels:
      app: productpage
  action: ALLOW
  rules:
  - from:
    - source:
       requestPrincipals: ["testing@secure.istio.io/testing@secure.istio.io"]
EOF

); }

