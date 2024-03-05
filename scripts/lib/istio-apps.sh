#!/bin/sh
set -u -o errexit -x

export ISTIO_APPS_BOOKINFO_NAMESPACE="bookinfo"

ISTIO_PRODUCTPAGE_APP_DIR="scripts/manifests/istio/productpage"

istio_apps_bookinfo() { (
  context="${1}"
  cluster_counter="${2}"

  if [ "${cluster_counter}" = "0" ]; then
    istio_apps_productpage_frontend "${context}" "${ISTIO_APPS_BOOKINFO_NAMESPACE}"
    istio_deploy_routing "${context}" "${ISTIO_APPS_BOOKINFO_NAMESPACE}"
  else
    istio_apps_productpage_backend "${context}" "${ISTIO_APPS_BOOKINFO_NAMESPACE}"
  fi
); }

istio_apps_productpage_frontend() { (
  context="${1}"
  namespace="${2}"

  kubectl create --context="${context}" namespace "${namespace}" || true

  kubectl apply --context="${context}" -n "${namespace}" -f ${ISTIO_PRODUCTPAGE_APP_DIR}/productpage.yaml
  kubectl apply --context="${context}" -n "${namespace}" -f ${ISTIO_PRODUCTPAGE_APP_DIR}/reviews-v3.yaml
  kubectl apply --context="${context}" -n "${namespace}" -f ${ISTIO_PRODUCTPAGE_APP_DIR}/ratings.yaml
  kubectl apply --context="${context}" -n "${namespace}" -f ${ISTIO_PRODUCTPAGE_APP_DIR}/details.yaml

  kubectl --context="${context}" -n "${namespace}" rollout status deploy/productpage-v1
  kubectl --context="${context}" -n "${namespace}" rollout status deploy/reviews-v3
  kubectl --context="${context}" -n "${namespace}" rollout status deploy/ratings-v1
  kubectl --context="${context}" -n "${namespace}" rollout status deploy/details-v1
); }

istio_apps_productpage_backend() { (
  context="${1}"
  namespace="${2}"

  kubectl create --context="${context}" namespace "${namespace}" || true

  kubectl apply --context="${context}" -n "${namespace}" -f ${ISTIO_PRODUCTPAGE_APP_DIR}/reviews-v1-v2.yaml
  kubectl apply --context="${context}" -n "${namespace}" -f ${ISTIO_PRODUCTPAGE_APP_DIR}/details.yaml

  kubectl --context="${context}" -n "${namespace}" rollout status deploy/reviews-v1
  kubectl --context="${context}" -n "${namespace}" rollout status deploy/reviews-v2
  kubectl --context="${context}" -n "${namespace}" rollout status deploy/details-v1
); }

istio_deploy_routing() { (
  context="${1}"
  namespace="${2}"
  kubectl apply --context="${context}" -n "${namespace}" \
    -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/bookinfo/networking/bookinfo-gateway.yaml
); }
