#!/usr/bin/env bash
# Installs the pinned CLI tools into ./bin.
#
# Nothing is installed system-wide and nothing needs sudo, so this repository
# cannot break a tool version another project on the same machine depends on.
# Everything here is downloaded for the current OS and architecture, which is
# what makes the same command work on WSL and on an Apple silicon Mac.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KIND_VERSION="v0.30.0"
HELM_VERSION="v3.16.4"
KUBECONFORM_VERSION="v0.6.7"
YQ_VERSION="v4.44.6"

OS="$(host_os)"
ARCH="$(host_arch)"

mkdir -p "${BIN_DIR}"

installed_version() {
  # Prints the version string of a locally installed tool, or nothing.
  local tool="$1"
  [ -x "${BIN_DIR}/${tool}" ] || return 0
  case "${tool}" in
    kind)        "${BIN_DIR}/kind" --version 2>/dev/null | awk '{print "v"$3}' ;;
    helm)        "${BIN_DIR}/helm" version --template '{{.Version}}' 2>/dev/null ;;
    kubeconform) "${BIN_DIR}/kubeconform" -v 2>/dev/null ;;
    yq)          "${BIN_DIR}/yq" --version 2>/dev/null | awk '{print $NF}' ;;
  esac
}

fetch() {
  local url="$1" dest="$2"
  curl --fail --silent --show-error --location --retry 3 --output "${dest}" "${url}"
}

install_kind() {
  if [ "$(installed_version kind)" = "${KIND_VERSION}" ]; then
    ok "kind ${KIND_VERSION}"
    return
  fi
  log "installing kind ${KIND_VERSION}"
  fetch "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${OS}-${ARCH}" "${BIN_DIR}/kind"
  chmod +x "${BIN_DIR}/kind"
  ok "kind ${KIND_VERSION}"
}

install_helm() {
  if [ "$(installed_version helm)" = "${HELM_VERSION}" ]; then
    ok "helm ${HELM_VERSION}"
    return
  fi
  log "installing helm ${HELM_VERSION}"
  local tmp
  tmp="$(mktemp -d)"
  fetch "https://get.helm.sh/helm-${HELM_VERSION}-${OS}-${ARCH}.tar.gz" "${tmp}/helm.tgz"
  tar -xzf "${tmp}/helm.tgz" -C "${tmp}"
  mv "${tmp}/${OS}-${ARCH}/helm" "${BIN_DIR}/helm"
  chmod +x "${BIN_DIR}/helm"
  rm -rf "${tmp}"
  ok "helm ${HELM_VERSION}"
}

install_kubeconform() {
  if [ "$(installed_version kubeconform)" = "${KUBECONFORM_VERSION}" ]; then
    ok "kubeconform ${KUBECONFORM_VERSION}"
    return
  fi
  log "installing kubeconform ${KUBECONFORM_VERSION}"
  local tmp asset_os
  tmp="$(mktemp -d)"
  # kubeconform capitalises the OS in its release asset names.
  case "${OS}" in
    linux) asset_os="linux" ;;
    darwin) asset_os="darwin" ;;
  esac
  fetch "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-${asset_os}-${ARCH}.tar.gz" "${tmp}/kc.tgz"
  tar -xzf "${tmp}/kc.tgz" -C "${tmp}" kubeconform
  mv "${tmp}/kubeconform" "${BIN_DIR}/kubeconform"
  chmod +x "${BIN_DIR}/kubeconform"
  rm -rf "${tmp}"
  ok "kubeconform ${KUBECONFORM_VERSION}"
}

install_yq() {
  if [ "$(installed_version yq)" = "${YQ_VERSION}" ]; then
    ok "yq ${YQ_VERSION}"
    return
  fi
  log "installing yq ${YQ_VERSION}"
  fetch "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_${OS}_${ARCH}" "${BIN_DIR}/yq"
  chmod +x "${BIN_DIR}/yq"
  ok "yq ${YQ_VERSION}"
}

log "resolving tooling for ${OS}/${ARCH} into ./bin"
install_kind
install_helm
install_kubeconform
install_yq

# kubectl and docker are expected to be provided by the machine: both are
# usually managed together with the container runtime or the OS package manager.
have kubectl || die "kubectl is required but not installed. See README.md, Prerequisites."
have docker || die "docker is required but not installed. See README.md, Prerequisites."
ok "kubectl $(kubectl version --client -o json 2>/dev/null | sed -n 's/.*"gitVersion": "\([^"]*\)".*/\1/p' | head -1)"
