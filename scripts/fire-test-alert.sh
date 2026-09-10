#!/usr/bin/env bash
# Sends a synthetic alert through the real alerting path.
#
# The alert is posted to Alertmanager, not to the application: it therefore has
# to pass through routing, grouping and inhibition, be delivered to the webhook
# receiver, cross the NetworkPolicy into the aspecta namespace and finally
# appear in the UI. That exercises every link in the chain in about ten seconds,
# instead of waiting minutes for a real failure to trip a rule.
#
# To watch a genuine rule fire instead, break the service on purpose:
#   kubectl -n aspecta scale deployment aspecta-backend --replicas=0
#   # AspectaDeploymentUnavailable fires after 3 minutes
#   kubectl -n aspecta scale deployment aspecta-backend --replicas=2

# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEVERITY="${SEVERITY:-warning}"
ALERT_NAME="${ALERT_NAME:-AspectaSyntheticProbe}"

kube -n "${MONITORING_NAMESPACE}" get statefulset alertmanager-kps-alertmanager >/dev/null 2>&1 \
  || die "Alertmanager is not installed. Bootstrap with monitoring enabled first."

curl_tls -fsS --max-time 10 "${ALERTMANAGER_URL}/api/v2/status" >/dev/null 2>&1 \
  || die "Alertmanager is not reachable at ${ALERTMANAGER_URL}"

# Alertmanager expects RFC3339 timestamps; -u keeps this working in any timezone
# and on both GNU and BSD date.
starts_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

log "posting ${ALERT_NAME} (severity=${SEVERITY}) to Alertmanager"
curl_tls -fsS --max-time 10 -X POST "${ALERTMANAGER_URL}/api/v2/alerts" \
  -H 'Content-Type: application/json' \
  -d '[{
        "labels": {
          "alertname": "'"${ALERT_NAME}"'",
          "severity": "'"${SEVERITY}"'",
          "namespace": "'"${APP_NAMESPACE}"'",
          "service": "aspecta-backend",
          "origin": "fire-test-alert.sh"
        },
        "annotations": {
          "summary": "Synthetic alert used to verify the notification path",
          "description": "Posted by scripts/fire-test-alert.sh. If this is visible in the Aspecta UI, then Prometheus rules, Alertmanager routing, the webhook receiver and the NetworkPolicy between the monitoring and aspecta namespaces all work."
        },
        "startsAt": "'"${starts_at}"'"
      }]' >/dev/null
ok "accepted by Alertmanager"

log "waiting for the application to receive the notification"
if wait_for "the alert to reach the UI" 120 \
  bash -c "curl --cacert '$(ca_cert)' -fsS --max-time 5 '${APP_URL}/api/v1/alerts' | grep -q '${ALERT_NAME}'"; then
  echo
  ok "delivered end to end"
  dim "      the alert is now visible at ${APP_URL} in the 'Alertmanager feed' panel"
  echo
  curl_tls -fsS "${APP_URL}/api/v1/alerts" | sed 's/,/,\n /g' | grep -A1 "${ALERT_NAME}" || true
else
  echo
  fail "the alert did not arrive within 120s"
  dim "      check the receiver:  kubectl -n ${MONITORING_NAMESPACE} logs sts/alertmanager-kps-alertmanager -c alertmanager | tail"
  dim "      check the webhook:   kubectl -n ${APP_NAMESPACE} logs deploy/aspecta-backend | tail"
  exit 1
fi
