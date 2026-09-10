#!/usr/bin/env bash
# Shared helpers for the scripts in this directory.
#
# Written for bash 3.2 so the same scripts run on the bash that ships with
# macOS as well as on WSL and Linux: no associative arrays, no mapfile, no
# GNU-only flags.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${REPO_ROOT}/bin"
# Locally installed tools win over anything on the system PATH, so every run
# uses the pinned versions from scripts/install-tools.sh.
PATH="${BIN_DIR}:${PATH}"
export PATH

CLUSTER_NAME="${CLUSTER_NAME:-aspecta}"
# kind names its kubeconfig entries kind-<cluster>. This environment renames
# them to the bare cluster name after creation (see rename_kube_entries), so
# every tool and every prompt shows "aspecta" rather than "kind-aspecta".
KUBE_CONTEXT="${KUBE_CONTEXT:-${CLUSTER_NAME}}"
KIND_CONTEXT="kind-${CLUSTER_NAME}"
APP_NAMESPACE="${APP_NAMESPACE:-aspecta}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
APP_HOST="${APP_HOST:-aspecta.localtest.me}"
CERT_MANAGER_NAMESPACE="${CERT_MANAGER_NAMESPACE:-cert-manager}"
# Where the environment's CA certificate is cached for curl and for the browser.
# Gitignored: it is derived state, re-extractable from the cluster at any time.
TLS_DIR="${TLS_DIR:-${REPO_ROOT}/.tls}"
CA_CERT_FILE="${CA_CERT_FILE:-${TLS_DIR}/aspecta-ca.crt}"
# Every host in this environment is HTTPS-only; port 80 answers with a redirect
# and nothing else.
APP_URL="${APP_URL:-https://${APP_HOST}}"
ARGOCD_URL="${ARGOCD_URL:-https://argocd.localtest.me}"
GRAFANA_URL="${GRAFANA_URL:-https://grafana.localtest.me}"
PROMETHEUS_URL="${PROMETHEUS_URL:-https://prometheus.localtest.me}"
ALERTMANAGER_URL="${ALERTMANAGER_URL:-https://alertmanager.localtest.me}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

log()  { printf '%s==>%s %s\n' "${C_BLUE}${C_BOLD}" "${C_RESET}" "$*"; }
ok()   { printf '%s  ok%s  %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }
warn() { printf '%swarn%s  %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
fail() { printf '%sfail%s  %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; }
dim()  { printf '%s%s%s\n' "${C_DIM}" "$*" "${C_RESET}"; }
die()  { fail "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# host_os / host_arch print the values used in upstream release asset names.
host_os() {
  case "$(uname -s)" in
    Linux) echo linux ;;
    Darwin) echo darwin ;;
    *) die "unsupported operating system: $(uname -s). Linux, WSL and macOS are supported." ;;
  esac
}

host_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) echo amd64 ;;
    arm64 | aarch64) echo arm64 ;;
    *) die "unsupported CPU architecture: $(uname -m)" ;;
  esac
}

kube() { kubectl --context "${KUBE_CONTEXT}" "$@"; }

# rename_kube_entries renames the context, cluster and user that `kind create
# cluster` writes as kind-<name> to just <name>. Surgical rather than a
# rewrite of the whole file: an operator's other clusters are none of this
# script's business. Idempotent - a second run finds nothing named kind-* and
# returns.
rename_kube_entries() {
  local cfg="${KUBECONFIG:-${HOME}/.kube/config}"
  [ -f "${cfg}" ] || return 0
  have yq || { warn "yq is missing; leaving the context named ${KIND_CONTEXT}"; return 0; }
  yq -e ".contexts[] | select(.name == \"${KIND_CONTEXT}\")" "${cfg}" >/dev/null 2>&1 || return 0
  yq -i "
    (.contexts[] | select(.name == \"${KIND_CONTEXT}\").name) = \"${KUBE_CONTEXT}\" |
    (.clusters[] | select(.name == \"${KIND_CONTEXT}\").name) = \"${KUBE_CONTEXT}\" |
    (.users[]    | select(.name == \"${KIND_CONTEXT}\").name) = \"${KUBE_CONTEXT}\" |
    (.contexts[] | select(.context.cluster == \"${KIND_CONTEXT}\").context.cluster) = \"${KUBE_CONTEXT}\" |
    (.contexts[] | select(.context.user == \"${KIND_CONTEXT}\").context.user) = \"${KUBE_CONTEXT}\" |
    (.current-context | select(. == \"${KIND_CONTEXT}\")) = \"${KUBE_CONTEXT}\"
  " "${cfg}"
}

# forget_kube_entries removes them again on teardown. kind cannot do it itself
# once they no longer carry the name it gave them.
forget_kube_entries() {
  kubectl config delete-context "${KUBE_CONTEXT}" >/dev/null 2>&1 || true
  kubectl config delete-cluster "${KUBE_CONTEXT}" >/dev/null 2>&1 || true
  kubectl config delete-user "${KUBE_CONTEXT}" >/dev/null 2>&1 || true
}

# wait_for polls a command until it succeeds. Used instead of `sleep` so a fast
# machine is not punished and a slow one is not cut off. Argument order:
# description, timeout in seconds, then the command.
wait_for() {
  local description="$1" timeout="$2"; shift 2
  local waited=0 interval=5
  printf '      %s' "waiting for ${description}"
  while [ "${waited}" -lt "${timeout}" ]; do
    if "$@" >/dev/null 2>&1; then
      printf ' %sok%s (%ss)\n' "${C_GREEN}" "${C_RESET}" "${waited}"
      return 0
    fi
    printf '.'
    sleep "${interval}"
    waited=$((waited + interval))
  done
  printf ' %stimed out after %ss%s\n' "${C_RED}" "${timeout}" "${C_RESET}"
  return 1
}

# random_token prints a URL-safe random string without depending on GNU base64.
random_token() {
  local bytes=32
  if have openssl; then
    openssl rand -hex "${bytes}"
  else
    LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c $((bytes * 2))
    echo
  fi
}

# b64decode reads base64 from stdin. GNU coreutils uses -d, BSD/macOS uses -D.
b64decode() {
  if base64 --help 2>&1 | grep -q -- '-d,'; then
    base64 -d
  else
    base64 -D 2>/dev/null || base64 -d
  fi
}

# ca_cert extracts this environment's root CA into ${CA_CERT_FILE} and prints
# the path. Every curl in these scripts goes through it, so a check that passes
# has genuinely validated the certificate chain - `curl -k` would have proved
# only that something answered on port 443.
ca_cert() {
  # Checked against the cluster once per script run, not cached blindly. The CA
  # is regenerated by every `make down && make up`, and a stale copy on disk
  # makes curl fail with "unable to get local issuer certificate" - which reads
  # like a broken ingress rather than a stale file, and costs an hour.
  if [ -n "${_CA_CERT_CHECKED:-}" ] && [ -s "${CA_CERT_FILE}" ]; then
    echo "${CA_CERT_FILE}"
    return 0
  fi

  mkdir -p "${TLS_DIR}"
  local live
  live="$(mktemp)"
  # tls.crt rather than ca.crt: for a self-signed CA Certificate the two are the
  # same certificate, and tls.crt is the key that is always present.
  if ! kube -n "${CERT_MANAGER_NAMESPACE}" get secret aspecta-ca-root \
      -o jsonpath='{.data.tls\.crt}' 2>/dev/null | b64decode > "${live}" 2>/dev/null \
      || [ ! -s "${live}" ]; then
    rm -f "${live}"
    # Leave any existing file alone: the cluster may simply be unreachable, and
    # deleting a usable CA over a transient failure helps nobody.
    [ -s "${CA_CERT_FILE}" ] && { echo "${CA_CERT_FILE}"; return 0; }
    return 1
  fi

  if ! cmp -s "${live}" "${CA_CERT_FILE}" 2>/dev/null; then
    mv "${live}" "${CA_CERT_FILE}"
    chmod 644 "${CA_CERT_FILE}"
  else
    rm -f "${live}"
  fi
  _CA_CERT_CHECKED=1
  echo "${CA_CERT_FILE}"
}

# curl_tls is curl pinned to this environment's CA. Falls back to plain curl if
# the CA cannot be read, so the caller still gets a real error about the
# certificate rather than a confusing one about a missing file.
curl_tls() {
  local ca
  if ca="$(ca_cert)"; then
    curl --cacert "${ca}" "$@"
  else
    curl "$@"
  fi
}

# git_remote_url prints the https form of the origin remote, so an ssh remote
# still yields a URL Argo CD can clone anonymously.
git_remote_url() {
  local url
  url="$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null || true)"
  [ -n "${url}" ] || return 1
  case "${url}" in
    git@github.com:*) url="https://github.com/${url#git@github.com:}" ;;
    ssh://git@github.com/*) url="https://github.com/${url#ssh://git@github.com/}" ;;
  esac
  case "${url}" in
    *.git) ;;
    *) url="${url}.git" ;;
  esac
  echo "${url}"
}

# github_owner extracts the owner segment of the origin remote, which doubles
# as the container registry namespace. Lowercased, because GHCR rejects an
# uppercase path and an owner is free to have capitals.
github_owner() {
  local url owner
  url="$(git_remote_url)" || return 1
  # The prefix strip below is a no-op on a remote that is not GitHub, so
  # without this guard a GitLab remote yielded "https:" and the first sign of
  # trouble was an ImagePullBackOff on ghcr.io/https:/aspecta-backend.
  case "${url}" in
    https://github.com/*) ;;
    *) return 1 ;;
  esac
  owner="${url#https://github.com/}"
  owner="${owner%%/*}"
  [ -n "${owner}" ] || return 1
  printf '%s\n' "${owner}" | tr '[:upper:]' '[:lower:]'
}

git_branch() {
  git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main
}
