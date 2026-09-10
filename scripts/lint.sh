#!/usr/bin/env bash
# Static validation of everything in the repository, identical to what CI runs.
#
# Manifests are rendered and then validated against the real Kubernetes API
# schemas, which catches a misspelled field that helm lint alone accepts.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KUBE_VERSION="${KUBE_VERSION:-1.34.0}"
failures=0
step() { log "$1"; }
run() {
  local description="$1"; shift
  if "$@" >/tmp/aspecta-lint.log 2>&1; then
    ok "${description}"
  else
    fail "${description}"
    sed 's/^/      /' /tmp/aspecta-lint.log | head -30
    failures=$((failures + 1))
  fi
}

have helm || die "helm is missing. Run scripts/install-tools.sh."
have kubeconform || die "kubeconform is missing. Run scripts/install-tools.sh."

step "Go"
if have go; then
  run "gofmt reports no unformatted files" bash -c "test -z \"\$(cd '${REPO_ROOT}/apps/backend' && gofmt -l .)\""
  run "go vet" bash -c "cd '${REPO_ROOT}/apps/backend' && go vet ./..."
  run "go test" bash -c "cd '${REPO_ROOT}/apps/backend' && go test ./..."
else
  warn "go is not installed, skipping the backend checks"
fi

step "Helm charts"
run "helm lint charts/aspecta" helm lint "${REPO_ROOT}/charts/aspecta"
run "helm lint gitops/root" helm lint "${REPO_ROOT}/gitops/root"
run "charts/aspecta renders" bash -c "helm template aspecta '${REPO_ROOT}/charts/aspecta' > /dev/null"
run "gitops/root renders" bash -c "helm template root '${REPO_ROOT}/gitops/root' > /dev/null"
# The schema must actually reject bad input, otherwise it gives false comfort.
run "values.schema.json rejects an invalid value" bash -c \
  "! helm template aspecta '${REPO_ROOT}/charts/aspecta' --set config.logLevel=nonsense > /dev/null 2>&1"

step "Kubernetes schema validation (API ${KUBE_VERSION})"
rendered="$(mktemp -d)"
helm template aspecta "${REPO_ROOT}/charts/aspecta" > "${rendered}/aspecta.yaml"
helm template root "${REPO_ROOT}/gitops/root" > "${rendered}/gitops.yaml"
cp "${REPO_ROOT}/platform/namespaces.yaml" "${rendered}/namespaces.yaml"
cp "${REPO_ROOT}/gitops/bootstrap/root-application.yaml" "${rendered}/root-app.yaml"

# Argo CD and Prometheus Operator CRDs are not in the upstream schema store, so
# their schemas are fetched from the datreeio catalogue of CRD schemas.
run "kubeconform" kubeconform \
  -kubernetes-version "${KUBE_VERSION}" \
  -strict \
  -summary \
  -ignore-missing-schemas \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  "${rendered}/aspecta.yaml" "${rendered}/gitops.yaml" "${rendered}/namespaces.yaml" "${rendered}/root-app.yaml"
rm -rf "${rendered}"

step "Shell scripts"
for script in "${REPO_ROOT}"/scripts/*.sh; do
  run "bash -n $(basename "${script}")" bash -n "${script}"
done
if have shellcheck; then
  run "shellcheck" shellcheck -x -S warning "${REPO_ROOT}"/scripts/*.sh
else
  dim "      shellcheck is not installed locally; CI runs it"
fi

step "Dashboards and workflows"
if have python3; then
  run "the Grafana dashboard is valid JSON" python3 -m json.tool "${REPO_ROOT}/charts/aspecta/dashboards/aspecta-overview.json"
  run "values.schema.json is valid JSON" python3 -m json.tool "${REPO_ROOT}/charts/aspecta/values.schema.json"
fi

echo
if [ "${failures}" -ne 0 ]; then
  die "${failures} check(s) failed"
fi
printf '%s%s%s\n' "${C_GREEN}${C_BOLD}" "All static checks passed." "${C_RESET}"
