#!/bin/sh
set -u -o errexit -x

ISTIO_CERTS_DIR="_output/certs"
ISTIO_ROOT_CA_CERT="${ISTIO_CERTS_DIR}/root-cert.pem"
ISTIO_ROOT_CA_KEY="${ISTIO_CERTS_DIR}/root-key.pem"
ISTIO_CA_CHAIN="${ISTIO_CERTS_DIR}/cert-chain.pem"
ISTIO_OPENSSL_CONFIG="${ISTIO_CERTS_DIR}/openssl-ca.conf"

istio_certs_openssl_ca_conf() { (
  ca_name="${1}"
  cat >"${ISTIO_OPENSSL_CONFIG}" <<EOF
[ req ]
encrypt_key = no
prompt = no
utf8 = yes
default_md = sha256
default_bits = 4096
req_extensions = req_ext
x509_extensions = req_ext
distinguished_name = req_dn

[ req_ext ]
subjectKeyIdentifier = hash
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, nonRepudiation, keyEncipherment, keyCertSign

[ req_dn ]
O = Istio
CN = ${ca_name}
EOF
  echo "${ISTIO_OPENSSL_CONFIG}"
); }

istio_certs_generate_root_ca() { (
  if [ -f "${ISTIO_ROOT_CA_CERT}" ]; then
    echo "Root CA already exists..."
    return
  fi

  mkdir -p "${ISTIO_CERTS_DIR}"
  openssl genrsa -out "${ISTIO_ROOT_CA_KEY}" 4096
  openssl req \
    -x509 \
    -new \
    -nodes \
    -key "${ISTIO_ROOT_CA_KEY}" \
    -sha256 \
    -days 3650 \
    -subj "/O=Istio/CN=Root CA" \
    -out "${ISTIO_ROOT_CA_CERT}" \
    -config "$(istio_certs_openssl_ca_conf "Root CA")"

  cat "${ISTIO_ROOT_CA_CERT}" >"${ISTIO_CA_CHAIN}"
); }

istio_certs_generate_intermediate_ca() { (
  context="${1}"
  namespace="${2}"

  # Define directory for the cluster's certificates within ISTIO_CERTS_DIR
  intermediate_ca_dir="${ISTIO_CERTS_DIR}/${context}"
  mkdir -p "${intermediate_ca_dir}"

  # Define file names for the cluster's certificates
  intermediate_ca_cert="${intermediate_ca_dir}/ca-cert.pem"
  intermediate_ca_key="${intermediate_ca_dir}/ca-key.pem"
  intermediate_ca_csr="${intermediate_ca_dir}/csr.pem"
  intermediate_ca_chain="${intermediate_ca_dir}/cert-chain.pem"

  if [ -f "${intermediate_ca_cert}" ]; then
    echo "Intermediate CA for cluster ${context} already exists..."
    return
  fi

  # Generate a CSR for the intermediate CA
  openssl req \
    -new \
    -sha256 \
    -nodes \
    -newkey rsa:4096 \
    -subj "/O=Istio/CN=Intermediate CA ${context}" \
    -keyout "${intermediate_ca_key}" \
    -out "${intermediate_ca_csr}"

  # Sign the intermediate CA CSR with the Root CA certificate
  openssl x509 \
    -req \
    -days 3650 \
    -CA "${ISTIO_ROOT_CA_CERT}" \
    -CAkey "${ISTIO_ROOT_CA_KEY}" \
    -set_serial 1 \
    -in "${intermediate_ca_csr}" \
    -out "${intermediate_ca_cert}" \
    -extfile "$(istio_certs_openssl_ca_conf "Intermediate CA")" \
    -extensions req_ext

  cat "${ISTIO_ROOT_CA_CERT}" "${intermediate_ca_cert}" >"${intermediate_ca_chain}"
  cat "${intermediate_ca_cert}" >>"${ISTIO_CA_CHAIN}"

  kubectl --context="${context}" create secret generic cacerts -n "${namespace}" \
    --from-file=ca-cert.pem="${intermediate_ca_cert}" \
    --from-file=ca-key.pem="${intermediate_ca_key}" \
    --from-file=root-cert.pem="${ISTIO_ROOT_CA_CERT}" \
    --from-file=cert-chain.pem="${intermediate_ca_chain}" \
    --dry-run=client -o yaml | kubectl --context="${context}" apply -f -
); }

istio_certs_generate_cert() { (
  context="${1}"
  namespace="${2}"
  cn="${3}"

  intermediate_ca_dir="${ISTIO_CERTS_DIR}/${context}"
  cert_dir="${intermediate_ca_dir}/certs/${cn}"
  cert="${cert_dir}/cert.pem"
  cert_csr="${cert_dir}/csr.pem"
  cert_key="${cert_dir}/key.pem"

  if [ -f "${cert}" ]; then
    echo "Certificate for CN ${cn} already exists..."
    return
  fi

  # Generate the private key
  mkdir -p "${cert_dir}"
  openssl genrsa -out "${cert_key}" 2048

  # Generate the certificate signing request (CSR)
  openssl req \
    -new \
    -key "${cert_key}" \
    -out "${cert_csr}" \
    -subj "/O=Istio/CN=${cn}" \
    -addext "subjectAltName = DNS:${cn}"

  # Sign the CSR with the intermediate CA's key
  intermediate_ca_cert="${intermediate_ca_dir}/ca-cert.pem"
  intermediate_ca_key="${intermediate_ca_dir}/ca-key.pem"

  openssl x509 \
    -req \
    -days 365 \
    -in "${cert_csr}" \
    -CA "${intermediate_ca_cert}" \
    -CAkey "${intermediate_ca_key}" \
    -CAcreateserial \
    -copy_extensions copy \
    -out "${cert}"

  # Create a secret in Kubernetes with the generated key and certificate
  kubectl --context="${context}" create secret tls "$(istio_certs_sanitize_cn "${cn}-tls")" -n "${namespace}" \
    --cert="${cert}" --key="${cert_key}"
); }

istio_certs_sanitize_cn() { (
  echo "${1}" | sed "s/\./-/g"
); }
