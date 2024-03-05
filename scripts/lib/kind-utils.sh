#!/bin/sh
set -u -o errexit -x

kind_utils_cluster_name() { (
  context="${1}"
  echo "${context}" | sed -e "s/^kind-//"
); }

kind_utils_context_name() { (
  cluster="${1}"
  echo "kind-${cluster}"
); }

kind_utils_node_name() { (
  cluster="${1}"
  echo "${cluster}-control-plane"
); }

kind_utils_node_host() { (
  cluster="${1}"
  echo "$(kind_utils_node_name "${cluster}").kind"
); }

kind_utils_trust_domain() { (
  cluster="${1}"
  echo "${cluster}.local"
); }

kind_utils_remote_clusters() { (
  context="${1}"
  remote_contexts="${2}"
  remote_clusters=""
  for remote_context in ${remote_contexts}; do
    if [ "${remote_context}" != "${context}" ]; then
      remote_clusters="${remote_clusters} $(kind_utils_cluster_name "${remote_context}")"
    fi
  done
  echo "${remote_clusters}" | xargs
); }

kind_utils_unique_port() { (
  cluster_counter="${1}"
  base_port="${2}"

  PORT_OFFSET=1000
  echo $((base_port + cluster_counter * PORT_OFFSET))
); }
