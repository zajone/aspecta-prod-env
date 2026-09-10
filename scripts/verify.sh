#!/usr/bin/env bash
# End-to-end verification of a running environment.
#
# Everything here is a black-box check through the same paths a user or an
# operator would take, so a pass means the environment genuinely works rather
# than that the manifests were accepted.

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

failures=0
check() {
  local description="$1"; shift
  if "$@" >/dev/null 2>&1; then
    ok "${description}"
  else
    fail "${description}"
    failures=$((failures + 1))
  fi
}

# expect_body runs a curl through the Ingress and greps the response.
#
# curl_tls, not curl: it validates the response against this environment's CA,
# so a pass means the certificate was trusted as well as the body correct.
expect_body() {
  local description="$1" needle="$2" url="$3"
  if curl_tls -fsS --max-time 10 "${url}" 2>/dev/null | grep -q "${needle}"; then
    ok "${description}"
  else
    fail "${description} (${url} did not contain '${needle}')"
    failures=$((failures + 1))
  fi
}

# expect_redirect_to_https asserts that the plaintext port answers with a
# permanent redirect and nothing else. This is the check that would catch an
# Ingress merged without TLS.
expect_redirect_to_https() {
  local host="$1" code location
  # Plain curl, not curl_tls: this request never gets as far as TLS. Only the
  # status line and the Location header matter, so the body is discarded.
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${host}/" 2>/dev/null || echo 000)"
  location="$(curl -s -o /dev/null -w '%{redirect_url}' --max-time 10 "http://${host}/" 2>/dev/null || true)"
  case "${code}" in
    301 | 308)
      case "${location}" in
        https://*)
          ok "http://${host} redirects to ${location} (${code})"
          ;;
        *)
          fail "http://${host} returned ${code} but pointed at '${location}', not an https URL"
          failures=$((failures + 1))
          ;;
      esac
      ;;
    *)
      fail "http://${host} answered ${code}; expected a 308 redirect to https"
      failures=$((failures + 1))
      ;;
  esac
}

kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}" || die "cluster '${CLUSTER_NAME}' not found. Run: make up"

log "cluster"
check "3 nodes are Ready" bash -c "kubectl --context ${KUBE_CONTEXT} get nodes --no-headers | grep -c ' Ready ' | grep -qx 3"

log "Argo CD"
for app in root namespaces prometheus-operator-crds cert-manager cert-manager-issuers ingress-nginx metrics-server monitoring aspecta; do
  status="$(kube -n "${ARGOCD_NAMESPACE}" get application "${app}" \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || echo missing)"
  case "${app}:${status}" in
    # These two are absent by design when the environment is bootstrapped with
    # MONITORING=off.
    monitoring:missing | prometheus-operator-crds:missing)
      warn "application ${app} is not installed (monitoring is off)"
      ;;
    *:Synced/Healthy)
      ok "application ${app} is ${status}"
      ;;
    *)
      fail "application ${app} is ${status}, expected Synced/Healthy"
      failures=$((failures + 1))
      ;;
  esac
done

log "workloads"
check "backend deployment is available" kube -n "${APP_NAMESPACE}" wait --for=condition=Available deployment/aspecta-backend --timeout=30s
check "frontend deployment is available" kube -n "${APP_NAMESPACE}" wait --for=condition=Available deployment/aspecta-frontend --timeout=30s
check "both HorizontalPodAutoscalers exist" bash -c "kubectl --context ${KUBE_CONTEXT} -n ${APP_NAMESPACE} get hpa aspecta-backend aspecta-frontend"
check "PodDisruptionBudgets are satisfied" bash -c "kubectl --context ${KUBE_CONTEXT} -n ${APP_NAMESPACE} get pdb -o jsonpath='{.items[*].status.currentHealthy}' | grep -qv '^0'"

# HPAs report <unknown> until metrics-server has served a window of data.
hpa_cpu="$(kube -n "${APP_NAMESPACE}" get hpa aspecta-backend -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null || true)"
if [ -n "${hpa_cpu}" ]; then
  ok "metrics-server feeds the autoscaler (backend at ${hpa_cpu}% CPU)"
else
  warn "the autoscaler has no CPU metrics yet; metrics-server needs about a minute after start-up"
fi

log "TLS"
if ca_cert >/dev/null; then
  ok "the environment CA is available ($(ca_cert))"
else
  fail "the environment CA secret cert-manager/aspecta-ca-root could not be read"
  failures=$((failures + 1))
fi

check "the CA ClusterIssuer is ready" bash -c \
  "kubectl --context ${KUBE_CONTEXT} get clusterissuer aspecta-ca -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -qx True"

# Every externally reachable host, checked two ways: the certificate chains to
# our CA and matches the hostname (curl_tls fails the request otherwise), and
# the plaintext port answers with nothing but a redirect.
#
# Grafana, Prometheus and Alertmanager are added to the list only when the
# monitoring stack is installed.
tls_hosts="${APP_HOST} argocd.localtest.me"
if kube -n "${MONITORING_NAMESPACE}" get deployment kps-grafana >/dev/null 2>&1; then
  tls_hosts="${tls_hosts} grafana.localtest.me prometheus.localtest.me alertmanager.localtest.me"
fi

for host in ${tls_hosts}; do
  # --head: any status is fine, including a 302 to a login page. What is being
  # asserted is the handshake, and -f would turn an authentication redirect into
  # a failure that says nothing about TLS.
  if curl_tls -sS --head --max-time 10 "https://${host}/" >/dev/null 2>&1; then
    ok "${host} presents a certificate trusted by the environment CA"
  else
    fail "${host} failed certificate validation against $(ca_cert 2>/dev/null || echo 'the environment CA')"
    failures=$((failures + 1))
  fi
  expect_redirect_to_https "${host}"
done

# TLS 1.0 and 1.1 must be refused outright, not merely deprioritised.
#
# OpenSSL 3.x refuses these protocols in the *client* by default, so the naive
# form of this check passed whatever the server did - it asserted a property
# of the local openssl build. Probe the client first and skip loudly rather
# than report a pass nobody tested.
for proto in tls1 tls1_1; do
  if ! openssl s_client -help 2>&1 | grep -q -- "-${proto} "; then
    warn "${proto}: this openssl will not offer it, so the server was not tested"
    continue
  fi
  if echo | openssl s_client -connect 127.0.0.1:443 -servername "${APP_HOST}" \
      "-${proto}" 2>/dev/null | grep -q "^ *Protocol *: *TLSv1\(\.1\)\?$"; then
    fail "the ingress accepted ${proto}, which ssl-protocols should have refused"
    failures=$((failures + 1))
  else
    ok "${proto} is refused"
  fi
done

# The positive half, which no client quirk can fake: the handshake that does
# succeed has to be TLS 1.2 or better.
# Parsed from the "New, TLSv1.3, Cipher is ..." summary line. The SSL-Session
# block that carries "Protocol :" is not printed for a connection closed this
# early, so keying on it silently produced an empty string.
negotiated="$(echo | openssl s_client -connect 127.0.0.1:443 -servername "${APP_HOST}" 2>/dev/null \
  | sed -n 's/^New, \([^,]*\),.*/\1/p' | head -1)"
case "${negotiated}" in
  TLSv1.2 | TLSv1.3)
    ok "the negotiated protocol is ${negotiated}"
    ;;
  *)
    fail "negotiated protocol was '${negotiated}', expected TLSv1.2 or TLSv1.3"
    failures=$((failures + 1))
    ;;
esac

# The header that used to bypass the redirect completely.
forged="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  -H 'X-Forwarded-Proto: https' "http://${APP_HOST}/" 2>/dev/null || echo 000)"
if [ "${forged}" = "308" ]; then
  ok "a forged X-Forwarded-Proto header does not bypass the redirect"
else
  fail "http://${APP_HOST}/ with a forged X-Forwarded-Proto answered ${forged}, expected 308"
  failures=$((failures + 1))
fi

hsts="$(curl_tls -sS -o /dev/null -D - --max-time 10 "${APP_URL}/" 2>/dev/null \
  | grep -i '^strict-transport-security:' || true)"
if [ -n "${hsts}" ]; then
  ok "HSTS is set ($(echo "${hsts}" | tr -d '\r' | cut -d' ' -f2-))"
else
  fail "no Strict-Transport-Security header on ${APP_URL}/"
  failures=$((failures + 1))
fi

log "application through the Ingress"
expect_body "the UI is served"            "Aspecta"                    "${APP_URL}/"
expect_body "the API answers"             '"objects"'                  "${APP_URL}/api/v1/stats"
expect_body "the catalogue is populated"  '"total":2[0-9]'             "${APP_URL}/api/v1/objects?size=50"
expect_body "a single object resolves"    "Andromeda"                  "${APP_URL}/api/v1/objects/m31"
expect_body "search works"                "Orion"                      "${APP_URL}/api/v1/objects?q=orion"
expect_body "the alert feed is exposed"   '"firing"'                   "${APP_URL}/api/v1/alerts"

# The drain control lives on the operations port now, so a POST from outside
# must never reach the handler. What comes back instead depends on who refuses
# it: /api/* is proxied to the backend, which has no such route and says 404,
# while any other path falls to the frontend's single-page fallback, where
# nginx refuses a POST to a static file with 405. Both mean "not reachable".
#
# The assertion is the negative one, because that is the property worth
# holding: a 200 would mean it is open, and a 401 or 501 would mean the
# request reached the backend handler after all.
for path in /api/v1/admin/maintenance /internal/maintenance; do
  status_code="$(curl_tls -s -o /dev/null -w '%{http_code}' --max-time 10 "${APP_URL}${path}" -X POST 2>/dev/null || echo 000)"
  case "${status_code}" in
    200 | 401 | 501)
      fail "${path} POST returned ${status_code} through the Ingress - the drain control is reachable from outside"
      failures=$((failures + 1))
      ;;
    404 | 405)
      ok "${path} POST is refused before it reaches the backend (${status_code})"
      ;;
    *)
      fail "${path} POST returned an unexpected ${status_code} through the Ingress"
      failures=$((failures + 1))
      ;;
  esac
done

log "in-cluster smoke suite"
check "the chart's own test suite passes inside the cluster" "${REPO_ROOT}/scripts/smoke.sh"

if kube -n "${MONITORING_NAMESPACE}" get deployment kps-grafana >/dev/null 2>&1; then
  log "observability"
  check "Prometheus is running" kube -n "${MONITORING_NAMESPACE}" wait --for=condition=Ready pod -l app.kubernetes.io/name=prometheus --timeout=30s
  check "Alertmanager is running" kube -n "${MONITORING_NAMESPACE}" wait --for=condition=Ready pod -l app.kubernetes.io/name=alertmanager --timeout=30s
  check "Grafana is running" kube -n "${MONITORING_NAMESPACE}" wait --for=condition=Ready pod -l app.kubernetes.io/name=grafana --timeout=30s
  check "the ServiceMonitor is registered" kube -n "${APP_NAMESPACE}" get servicemonitor aspecta-backend
  check "the alert rules are registered" kube -n "${APP_NAMESPACE}" get prometheusrule aspecta
  check "the dashboard ConfigMap is labelled for the Grafana sidecar" bash -c "kubectl --context ${KUBE_CONTEXT} -n ${APP_NAMESPACE} get configmap aspecta-dashboard -o jsonpath='{.metadata.labels.grafana_dashboard}' | grep -qx 1"

  # Ask Prometheus itself whether it is scraping the application and whether the
  # rules loaded - the two things that decide if the alerts can ever fire.
  targets="$(curl_tls -fsS --max-time 10 "${PROMETHEUS_URL}/api/v1/targets?state=active" 2>/dev/null || true)"
  if echo "${targets}" | grep -q 'aspecta-backend'; then
    up_count="$(echo "${targets}" | tr ',' '\n' | grep -c '"health":"up"' || true)"
    ok "Prometheus is scraping aspecta-backend (${up_count} healthy targets in total)"
  else
    fail "Prometheus has no aspecta-backend target"
    failures=$((failures + 1))
  fi

  rules="$(curl_tls -fsS --max-time 10 "${PROMETHEUS_URL}/api/v1/rules" 2>/dev/null || true)"
  for rule in AspectaBackendDown AspectaHighErrorRate AspectaCatalogueEmpty AspectaDeploymentUnavailable; do
    if echo "${rules}" | grep -q "${rule}"; then
      ok "alert rule ${rule} is loaded"
    else
      fail "alert rule ${rule} is not loaded in Prometheus"
      failures=$((failures + 1))
    fi
  done

  metric="$(curl_tls -fsS --max-time 10 --get "${PROMETHEUS_URL}/api/v1/query" \
    --data-urlencode 'query=aspecta_catalogue_objects' 2>/dev/null || true)"
  if echo "${metric}" | grep -q '"value"'; then
    ok "application metrics are queryable in Prometheus"
  else
    fail "aspecta_catalogue_objects returned no data from Prometheus"
    failures=$((failures + 1))
  fi

  expect_body "Grafana is reachable and healthy" '"database": *"ok"' "${GRAFANA_URL}/api/health"
  expect_body "Alertmanager is reachable" '"cluster"' "${ALERTMANAGER_URL}/api/v2/status"
else
  warn "the monitoring stack is not installed, skipping the observability checks"
fi

echo
if [ "${failures}" -ne 0 ]; then
  die "${failures} check(s) failed"
fi
printf '%s%s%s\n' "${C_GREEN}${C_BOLD}" "The environment is verified end to end." "${C_RESET}"
