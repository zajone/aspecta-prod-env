#!/usr/bin/env bash
# Proves the security controls instead of describing them.
#
# Every claim the README makes about RBAC, NetworkPolicies and Pod Security
# Admission is asserted here against the running cluster - including the
# negative cases, which is where a policy that only looks correct usually fails.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

failures=0
PROBE_NS="aspecta-security-probe"
# Reuse an image that is already on the nodes, so the probes need no registry.
PROBE_IMAGE="$(kube -n "${APP_NAMESPACE}" get deployment aspecta-frontend \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo '')"

kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}" || die "cluster '${CLUSTER_NAME}' not found. Run: make up"
[ -n "${PROBE_IMAGE}" ] || die "the application is not deployed yet. Run: make up"

pass() { ok "$1"; }
bad()  { fail "$1"; failures=$((failures + 1)); }

# assert_blocked expects a connection to have been dropped by a NetworkPolicy.
# A blocked connection times out, so the probe reports "blocked".
assert_blocked() {
  local description="$1" result="$2"
  if [ "${result}" = "blocked" ]; then
    pass "${description}"
  else
    bad "${description} - the connection was ${result}"
  fi
}

# can_i asserts the outcome of an authorization check for a ServiceAccount.
#
# --quiet is what makes this reliable: without it kubectl both prints the answer
# and exits non-zero on "no", so any fallback in a command substitution ends up
# appended to the output.
can_i() {
  local expected="$1" subject="$2" verb="$3" resource="$4"; shift 4
  local actual=no
  if kube auth can-i "${verb}" "${resource}" --quiet \
    --as="system:serviceaccount:${APP_NAMESPACE}:${subject}" -n "${APP_NAMESPACE}" "$@" 2>/dev/null; then
    actual=yes
  fi
  if [ "${actual}" = "${expected}" ]; then
    pass "${subject}: ${verb} ${resource} $* -> ${actual}"
  else
    bad "${subject}: expected '${expected}' for ${verb} ${resource} $*, got '${actual}'"
  fi
}

# can_i_in_namespace is the same assertion against a different namespace, which
# is how a namespace-scoped Role is shown to stop at its own boundary.
can_i_in_namespace() {
  local expected="$1" namespace="$2" subject="$3" verb="$4" resource="$5"
  local actual=no
  if kube auth can-i "${verb}" "${resource}" --quiet \
    --as="system:serviceaccount:${APP_NAMESPACE}:${subject}" -n "${namespace}" 2>/dev/null; then
    actual=yes
  fi
  if [ "${actual}" = "${expected}" ]; then
    pass "${subject}: ${verb} ${resource} in namespace ${namespace} -> ${actual}"
  else
    bad "${subject}: expected '${expected}' for ${verb} ${resource} in namespace ${namespace}, got '${actual}'"
  fi
}

cleanup() {
  kube delete namespace "${PROBE_NS}" --wait=false >/dev/null 2>&1 || true
  kube -n "${APP_NAMESPACE}" delete pod inside-probe --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
log "RBAC: the workload identity has no access to the API"
# ---------------------------------------------------------------------------
can_i no aspecta get pods
can_i no aspecta list secrets
can_i no aspecta get configmaps

token_volumes="$(kube -n "${APP_NAMESPACE}" get pods -l app.kubernetes.io/part-of=aspecta \
  -o jsonpath='{range .items[*]}{.spec.volumes[*].name}{"\n"}{end}' 2>/dev/null | grep -c 'kube-api-access' || true)"
if [ "${token_volumes}" = "0" ]; then
  pass "no ServiceAccount token is projected into any application pod"
else
  bad "${token_volumes} pod(s) still have a projected ServiceAccount token"
fi

# ---------------------------------------------------------------------------
log "RBAC: the operator roles are scoped, and neither can read the admin token"
# ---------------------------------------------------------------------------
can_i yes aspecta-viewer get pods
can_i yes aspecta-viewer get pods/log
can_i no  aspecta-viewer delete pods
can_i no  aspecta-viewer get secrets
can_i no  aspecta-viewer patch deployments

can_i yes aspecta-operator patch deployments
can_i yes aspecta-operator delete pods
can_i yes aspecta-operator update deployments --subresource=scale
can_i no  aspecta-operator create deployments
can_i no  aspecta-operator get secrets

# A namespace-scoped Role must not grant anything in another namespace.
for subject in aspecta-viewer aspecta-operator; do
  can_i_in_namespace no "${MONITORING_NAMESPACE}" "${subject}" get pods
  can_i_in_namespace no "${ARGOCD_NAMESPACE}" "${subject}" get secrets
done

# ---------------------------------------------------------------------------
log "Pod Security Admission: a privileged pod is rejected by the API server"
# ---------------------------------------------------------------------------
psa_output="$(kube -n "${APP_NAMESPACE}" run psa-probe --image="${PROBE_IMAGE}" --restart=Never \
  --dry-run=server --overrides='{"spec":{"containers":[{"name":"psa-probe","image":"'"${PROBE_IMAGE}"'","securityContext":{"privileged":true}}]}}' 2>&1 || true)"
if echo "${psa_output}" | grep -qi 'violate.*PodSecurity\|forbidden'; then
  pass "a privileged container cannot be created in the ${APP_NAMESPACE} namespace"
else
  bad "the API server accepted a privileged pod: ${psa_output}"
fi

# ---------------------------------------------------------------------------
log "NetworkPolicy: traffic from another namespace is dropped"
# ---------------------------------------------------------------------------
kube create namespace "${PROBE_NS}" >/dev/null 2>&1 || true
cat <<PROBE | kube apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: outside-probe
  namespace: ${PROBE_NS}
  labels:
    app: probe
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  containers:
    - name: probe
      image: ${PROBE_IMAGE}
      command: ["sleep", "600"]
PROBE
wait_for "the probe pod outside the namespace" 120 \
  kube -n "${PROBE_NS}" wait --for=condition=Ready pod/outside-probe --timeout=10s

# busybox wget is present in the frontend image, so the probe needs no extra
# image pull. A blocked connection times out rather than being refused.
probe_outside() {
  kube -n "${PROBE_NS}" exec outside-probe -- \
    /bin/sh -c "wget -q -T 4 -O- '$1' >/dev/null 2>&1 && echo reachable || echo blocked" 2>/dev/null
}

assert_blocked "the frontend is unreachable from another namespace" \
  "$(probe_outside "http://aspecta-frontend.${APP_NAMESPACE}.svc:8080/healthz")"

assert_blocked "the backend API is unreachable from another namespace" \
  "$(probe_outside "http://aspecta-backend.${APP_NAMESPACE}.svc:8080/api/v1/stats")"

assert_blocked "the metrics port is unreachable from a non-monitoring namespace" \
  "$(probe_outside "http://aspecta-backend.${APP_NAMESPACE}.svc:9090/metrics")"

# ---------------------------------------------------------------------------
log "NetworkPolicy: an unlabelled pod inside the namespace is also dropped"
# ---------------------------------------------------------------------------
# The default-deny policy selects every pod, so being in the right namespace is
# not enough - which is the difference between a perimeter and zero trust.
cat <<PROBE | kube apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: inside-probe
  namespace: ${APP_NAMESPACE}
  labels:
    app: probe
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 101
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: probe
      image: ${PROBE_IMAGE}
      command: ["sleep", "600"]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: [ALL]
PROBE
wait_for "the probe pod inside the namespace" 120 \
  kube -n "${APP_NAMESPACE}" wait --for=condition=Ready pod/inside-probe --timeout=10s

probe_inside() {
  kube -n "${APP_NAMESPACE}" exec inside-probe -- \
    /bin/sh -c "wget -q -T 4 -O- '$1' >/dev/null 2>&1 && echo reachable || echo blocked" 2>/dev/null
}

assert_blocked "an unlabelled pod in the namespace cannot reach the backend" \
  "$(probe_inside "http://aspecta-backend.${APP_NAMESPACE}.svc:8080/api/v1/stats")"

# No egress rule allows internet traffic, and an IP literal removes DNS from
# the equation.
assert_blocked "egress to the internet is denied" "$(probe_inside "http://1.1.1.1")"

# ---------------------------------------------------------------------------
log "The allowed paths still work"
# ---------------------------------------------------------------------------
if curl_tls -fsS --max-time 10 "${APP_URL}/api/v1/stats" >/dev/null 2>&1; then
  pass "the Ingress controller reaches the frontend, and the frontend reaches the API"
else
  bad "the application is not reachable through the Ingress"
fi

scrape_health="$(curl_tls -fsS --max-time 10 "${PROMETHEUS_URL}/api/v1/targets?state=active" 2>/dev/null \
  | tr '}' '\n' | grep 'aspecta-backend' | grep -c '"health":"up"' || true)"
if [ "${scrape_health}" -gt 0 ] 2>/dev/null; then
  pass "Prometheus in the monitoring namespace reaches the metrics port (${scrape_health} target(s) up)"
else
  warn "no healthy aspecta-backend scrape target; skipped if the monitoring stack is not installed"
fi

# ---------------------------------------------------------------------------
log "Secrets are not in the repository"
# ---------------------------------------------------------------------------
rendered_secrets="$(helm template aspecta "${REPO_ROOT}/charts/aspecta" 2>/dev/null | grep -c '^kind: Secret' || true)"
if [ "${rendered_secrets}" = "0" ]; then
  pass "the chart renders no Secret; the admin token is provisioned out of band"
else
  bad "the chart renders ${rendered_secrets} Secret(s) from values in git"
fi

echo
if [ "${failures}" -ne 0 ]; then
  die "${failures} security assertion(s) failed"
fi
printf '%s%s%s\n' "${C_GREEN}${C_BOLD}" "All security controls verified." "${C_RESET}"
