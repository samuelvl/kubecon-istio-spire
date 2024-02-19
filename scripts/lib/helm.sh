#!/bin/sh
set -u -o errexit -x

BIN_DIR=${BIN_DIR:-.}
HELM_CLI="${BIN_DIR}/helm"
HELM_VERSION="3.14.1"

helm_install_cli() {
  echo "Downloading Helm cli tool to ${BIN_DIR} output folder"

  ARCH="$(uname -m)"
  if [ "$ARCH" = "x86_64" ]; then
    ARCH="amd64"
    OS="linux"
  elif [ "$ARCH" = "arm64" ]; then
    ARCH="arm64"
    OS="darwin"
  fi

  mkdir -p "${BIN_DIR}"
  curl -L -s \
    "https://get.helm.sh/helm-v${HELM_VERSION}-${OS}-${ARCH}.tar.gz" | tar -xvz -C "${BIN_DIR}"
  cp "${BIN_DIR}/${OS}-${ARCH}/helm" "${HELM_CLI}"
  chmod +x "${HELM_CLI}"
}
