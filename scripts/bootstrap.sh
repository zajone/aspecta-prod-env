#!/usr/bin/env bash
# Creates the whole environment from an empty machine.
#
# This is the only imperative step in the repository. It provisions the cluster,
# installs Argo CD and hands over a single root Application; every other object
# in the cluster is then created by Argo CD from git. Re-running it is safe -
# each step checks the current state first.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKIP_PREFLIGHT="${SKIP_PREFLIGHT:-false}"
MONITORING="${MONITORING:-on}"
ARGOCD_CHART_VERSION="10.8.4"
ARGOCD_CHART_REPO="https://argoproj.github.io/argo-helm"

start_time="$(date +%s)"

# --- 0. prerequisites -------------------------------------------------------
if [ "${SKIP_PREFLIGHT}" != "true" ]; then
  "${REPO_ROOT}/scripts/preflight.sh"
  echo
fi

"${REPO_ROOT}/scripts/install-tools.sh"
echo

# --- 1. identity of this checkout -------------------------------------------
# Everything that differs between this repository and a fork is derived here,
# so no file has to be edited after forking.
REPO_URL="${REPO_URL:-$(git_remote_url || true)}"
TARGET_REVISION="${TARGET_REVISION:-$(git_branch)}"
IMAGE_OWNER="${IMAGE_OWNER:-$(github_owner || true)}"

if [ -z "${REPO_URL}" ]; then
  die "no git remote 'origin' found. Push this repository to GitHub first, or run: REPO_URL=https://github.com/<owner>/<repo>.git IMAGE_OWNER=<owner> make up"
fi

# An empty owner used to travel all the way to an image reference with a
# missing path segment, where the first symptom was ImagePullBackOff. Say so
# here instead, and name the override.
if [ -z "${IMAGE_OWNER}" ]; then
  die "could not derive the registry namespace from '${REPO_URL}' (only github.com remotes are recognised). Set it explicitly: IMAGE_OWNER=<owner> make up"
fi

log "environment"
dim "      repository   ${REPO_URL}"
dim "      revision     ${TARGET_REVISION}"
dim "      image owner  ${IMAGE_OWNER}"
dim "      monitoring   ${MONITORING}"
echo

# --- 2. cluster -------------------------------------------------------------
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  ok "kind cluster '${CLUSTER_NAME}' already exists"
else
  log "creating the kind cluster (3 nodes, this takes a minute)"
  kind create cluster --config "${REPO_ROOT}/clusters/kind/cluster.yaml" --wait 120s
  ok "cluster created"
fi
rename_kube_entries
kubectl config use-context "${KUBE_CONTEXT}" >/dev/null
wait_for "all nodes to be Ready" 180 kube wait --for=condition=Ready nodes --all --timeout=10s
echo

# --- 3. images --------------------------------------------------------------
# Built and loaded before Argo CD deploys the application, so the very first
# sync finds its images already present on the nodes.
"${REPO_ROOT}/scripts/build-images.sh"
echo

# --- 4. namespaces ----------------------------------------------------------
# Applied from the same file Argo CD will own from here on, so the Pod Security
# Admission labels exist before the first workload is admitted.
log "creating namespaces with Pod Security Admission labels"
kube apply -f "${REPO_ROOT}/platform/namespaces.yaml" >/dev/null
ok "namespaces aspecta, monitoring, ingress-nginx, cert-manager, argocd"
echo

# --- 5. secrets -------------------------------------------------------------
# Credentials are generated on the machine and never committed. Existing
# secrets are left alone so a re-run does not rotate them.
log "provisioning secrets out of band"

if kube -n "${APP_NAMESPACE}" get secret aspecta-admin >/dev/null 2>&1; then
  ok "aspecta-admin exists"
else
  kube -n "${APP_NAMESPACE}" create secret generic aspecta-admin \
    --from-literal="ADMIN_TOKEN=$(random_token)" >/dev/null
  kube -n "${APP_NAMESPACE}" label secret aspecta-admin \
    app.kubernetes.io/part-of=aspecta \
    aspecta.io/managed-by=bootstrap >/dev/null
  ok "aspecta-admin created with a random token"
fi

if kube -n "${MONITORING_NAMESPACE}" get secret grafana-admin >/dev/null 2>&1; then
  ok "grafana-admin exists"
else
  kube -n "${MONITORING_NAMESPACE}" create secret generic grafana-admin \
    --from-literal=admin-user=admin \
    --from-literal="admin-password=$(random_token | cut -c1-24)" >/dev/null
  ok "grafana-admin created with a random password"
fi
echo

# --- 6. Argo CD -------------------------------------------------------------
log "installing Argo CD ${ARGOCD_CHART_VERSION}"
helm repo add argo "${ARGOCD_CHART_REPO}" >/dev/null 2>&1 || true
helm repo update argo >/dev/null 2>&1
helm upgrade --install argocd argo/argo-cd \
  --version "${ARGOCD_CHART_VERSION}" \
  --namespace "${ARGOCD_NAMESPACE}" \
  --values "${REPO_ROOT}/platform/argocd/values.yaml" \
  --kube-context "${KUBE_CONTEXT}" \
  --wait --timeout 8m >/dev/null
ok "Argo CD is running"
echo

# --- 7. hand over to GitOps -------------------------------------------------
log "applying the root Application"
monitoring_enabled=true
[ "${MONITORING}" = "off" ] && monitoring_enabled=false

rendered="$(mktemp)"
# sed rather than envsubst: envsubst is part of gettext and is not installed by
# default on macOS.
sed -e "s|__REPO_URL__|${REPO_URL}|g" \
    -e "s|__TARGET_REVISION__|${TARGET_REVISION}|g" \
    -e "s|__IMAGE_OWNER__|${IMAGE_OWNER}|g" \
    "${REPO_ROOT}/gitops/bootstrap/root-application.yaml" > "${rendered}"

if [ "${monitoring_enabled}" = "false" ]; then
  # Inserted into the parameter list by path, not appended to the file.
  # Appending only worked while helm.parameters happened to be the last block
  # in the manifest; once syncPolicy moved below it the text landed under
  # syncOptions and the whole document stopped being valid YAML, so the
  # documented low-memory path failed at kubectl apply.
  yq -i '.spec.source.helm.parameters += [{"name": "monitoring", "value": "false"}]' "${rendered}"
fi

kube apply -f "${rendered}" >/dev/null
rm -f "${rendered}"
ok "root Application applied - Argo CD now owns the cluster"
echo

# --- 8. wait for the environment to converge --------------------------------
log "waiting for Argo CD to converge (first sync pulls the upstream charts)"
wait_for "the child Applications to appear" 180 \
  kube -n "${ARGOCD_NAMESPACE}" get application aspecta

# cert-manager and its CA come first (sync waves 0 and 1), and every Ingress
# after them depends on the issuer existing.
wait_for "cert-manager to be ready" 300 \
  kube -n "${CERT_MANAGER_NAMESPACE}" wait --for=condition=Available deployment --all --timeout=10s

# --ignore-not-found would make `get` succeed while the issuer does not exist
# yet, so the Ready condition itself has to be the thing that is matched.
wait_for "the certificate authority to be issued" 300 bash -c \
  "kubectl --context '${KUBE_CONTEXT}' get clusterissuer aspecta-ca \
     -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep -qx True"

wait_for "ingress-nginx to be ready" 300 \
  kube -n ingress-nginx wait --for=condition=Available deployment \
  -l app.kubernetes.io/component=controller --timeout=10s

if [ "${monitoring_enabled}" = "true" ]; then
  wait_for "the monitoring stack to be ready" 900 \
    kube -n "${MONITORING_NAMESPACE}" wait --for=condition=Ready pod \
    -l app.kubernetes.io/name=grafana --timeout=10s
fi

wait_for "the application to be ready" 600 \
  kube -n "${APP_NAMESPACE}" wait --for=condition=Available deployment --all --timeout=10s

wait_for "every TLS certificate to be issued" 300 \
  kube wait --for=condition=Ready certificate --all --all-namespaces --timeout=10s
echo

# --- 9. summary -------------------------------------------------------------
elapsed=$(( $(date +%s) - start_time ))
argocd_password="$(kube -n "${ARGOCD_NAMESPACE}" get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | b64decode 2>/dev/null || echo '<already rotated>')"
grafana_password="$(kube -n "${MONITORING_NAMESPACE}" get secret grafana-admin \
  -o jsonpath='{.data.admin-password}' 2>/dev/null | b64decode 2>/dev/null || echo '<not installed>')"

printf '\n%s%s%s\n' "${C_GREEN}${C_BOLD}" "Environment ready in ${elapsed}s." "${C_RESET}"
cat <<SUMMARY

  Application     ${APP_URL}
  Argo CD         ${ARGOCD_URL}        admin / ${argocd_password}
SUMMARY
if [ "${monitoring_enabled}" = "true" ]; then
cat <<SUMMARY
  Grafana         ${GRAFANA_URL}       admin / ${grafana_password}
  Prometheus      ${PROMETHEUS_URL}
  Alertmanager    ${ALERTMANAGER_URL}
SUMMARY
fi
cat <<'SUMMARY'

  Every host is HTTPS only; port 80 answers with a redirect and nothing else.
  The certificates come from this environment's own CA, so trust it once:

    make trust-ca          install the CA into the system and browser trust store

  Until then a browser shows a certificate warning, and curl needs
  --cacert .tls/aspecta-ca.crt. The scripts below already do.

  Next steps
    make verify            end-to-end check of the whole environment
    make verify-security   prove the RBAC and NetworkPolicy restrictions
    make test-alert        send a test alert through Alertmanager into the UI
    make status            what Argo CD thinks of the cluster right now

SUMMARY
