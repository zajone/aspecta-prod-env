#!/usr/bin/env bash
# Runs the chart's in-cluster smoke suite against a running release.
#
# `helm test` cannot be used here: Argo CD deploys with `helm template` and
# server-side apply, so there is no Helm release object in the cluster to test.
# This renders the very same test manifests the chart ships, applies them,
# waits for the pod to finish and cleans up - so the assertions are identical
# whether the release was installed by Helm (CI) or by Argo CD (this cluster).

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RELEASE="${RELEASE:-aspecta}"
POD="${RELEASE}-test"

have helm || die "helm is missing. Run scripts/install-tools.sh first."

cleanup() {
  helm template "${RELEASE}" "${REPO_ROOT}/charts/aspecta" \
    --namespace "${APP_NAMESPACE}" \
    --show-only templates/tests/api-test.yaml 2>/dev/null \
    | kube delete -f - --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "rendering and applying the chart's test manifests"
# The test pod is denied by the namespace's default-deny policy on its own, so
# the two NetworkPolicies rendered alongside it are part of the suite.
if ! helm template "${RELEASE}" "${REPO_ROOT}/charts/aspecta" \
  --namespace "${APP_NAMESPACE}" \
  --show-only templates/tests/api-test.yaml \
  | kube apply -f - >/dev/null; then
  die "could not apply the test manifests"
fi

log "waiting for the smoke suite to finish"
deadline=$((SECONDS + 180))
phase=""
while [ "${SECONDS}" -lt "${deadline}" ]; do
  phase="$(kube -n "${APP_NAMESPACE}" get pod "${POD}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  case "${phase}" in
    Succeeded | Failed) break ;;
  esac
  sleep 3
done

echo
kube -n "${APP_NAMESPACE}" logs "${POD}" 2>/dev/null | sed 's/^/      /' || true
echo

case "${phase}" in
  Succeeded) ok "the in-cluster smoke suite passed" ;;
  Failed)    die "the in-cluster smoke suite failed" ;;
  *)         die "the smoke pod did not finish within 180s (phase: ${phase:-unknown})" ;;
esac
