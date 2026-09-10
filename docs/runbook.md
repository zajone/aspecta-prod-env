# Runbook

Every alert in `charts/aspecta/templates/prometheusrule.yaml` carries a
`runbook_url` pointing at its section below. The anchors are lowercase alert
names, so an alert in Alertmanager links straight to its own instructions.

Before anything else, in every case:

```bash
make status                                   # Argo CD's view of the world
kubectl -n aspecta get pods -o wide           # where the replicas are and why
kubectl -n aspecta logs -l app.kubernetes.io/component=backend --tail=100
```

Remember that **the cluster self-heals from git**. A fix applied with `kubectl`
survives only until the next reconciliation (three minutes at most). Use
`kubectl` to diagnose and to stop the bleeding; use a commit to actually fix.

---

## AspectaBackendDown

`up{job="aspecta-backend"} == 0` for 2 minutes — Prometheus can reach the
target's endpoint but the replica does not answer.

**Likely causes**, in the order they occur in practice:

1. The container is crash-looping — a bad image or a bad configuration value.
2. The process is alive but wedged, so the operations port does not respond.
3. The node hosting the replica is unhealthy.

```bash
kubectl -n aspecta get pods -l app.kubernetes.io/component=backend
kubectl -n aspecta describe pod <pod>          # events, restart count, last state
kubectl -n aspecta logs <pod> --previous       # why the previous container died
```

**Mitigation.** If a single replica is affected and others are healthy, the
Service has already removed it; delete the pod and let the ReplicaSet replace it:

```bash
kubectl -n aspecta delete pod <pod>
```

If every replica is down, this is a bad release — go to
[AspectaCatalogueEmpty](#aspectacatalogueempty) for the rollback procedure.

---

## AspectaBackendTargetMissing

`absent(up{job="aspecta-backend"})` for 5 minutes — Prometheus has no target at
all. This is a *different* failure from a target being down: the object that
told Prometheus to scrape is gone. `up` cannot report zero for something
Prometheus no longer knows about, which is why this alert exists separately.

```bash
kubectl -n aspecta get servicemonitor aspecta-backend      # does it still exist?
kubectl -n aspecta get svc aspecta-backend -o yaml         # does the selector still match?
kubectl -n aspecta get endpoints aspecta-backend           # are there any endpoints?
kubectl -n monitoring logs sts/prometheus-kps-prometheus -c prometheus --tail=50
```

**Likely causes.** The ServiceMonitor was pruned (a file deleted from git), the
Service selector no longer matches the pod labels after a template change, or
the whole application was deleted. Check `make status` — if the `aspecta`
Application is missing or `OutOfSync`, the cause is in git, not in the cluster.

---

## AspectaDeploymentUnavailable

`kube_deployment_status_replicas_available == 0` for 3 minutes — the service is
down for users even if pods exist.

```bash
kubectl -n aspecta rollout status deployment/<name> --timeout=30s
kubectl -n aspecta get events --sort-by=.lastTimestamp | tail -20
kubectl -n aspecta describe pod <pod> | sed -n '/Events/,$p'
```

**Likely causes and fixes:**

| Cause | Signal | Fix |
|---|---|---|
| Image cannot be pulled | `ImagePullBackOff` | The GHCR package is private, or the tag does not exist. `make build` to load locally, or fix the visibility. |
| No node has capacity | `Pending`, `Insufficient memory` | `kubectl top nodes`; drop the monitoring stack (`make up MONITORING=off`) or raise the WSL memory ceiling. |
| Readiness never passes | pods `Running` but `0/1 Ready` | `kubectl -n aspecta port-forward <pod> 9090:9090` then `curl localhost:9090/readyz` — the body says whether it is draining or in maintenance. |
| The rollout is blocked by the PDB | `rollout status` hangs | Expected during a node drain with `minAvailable: 1` and one replica; scale up first. |

---

## AspectaCatalogueEmpty

`aspecta_catalogue_objects == 0` — a replica loaded no catalogue objects. The
dataset is embedded in the binary, so this can only mean **a broken image
reached production**. It is a critical alert because the service is answering
requests with an empty result set rather than failing, which no infrastructure
metric would catch.

**Roll back immediately.** The deployment is a commit, so the rollback is too:

```bash
git log --oneline -- charts/aspecta/Chart.yaml     # find the last good release
git revert <bad release commit>
git push                                           # Argo CD rolls back within 3 min
```

To stop the bleeding before the revert lands:

```bash
kubectl -n aspecta rollout undo deployment/aspecta-backend
```

Self-heal will restore the git state, which is exactly why the revert is the
real fix. Then work out how the image passed CI: `go test ./...` covers the
"catalogue must not be empty" case in `internal/catalogue/catalogue_test.go`,
and `helm test` asserts a populated catalogue — so a failure here means one of
those gates was skipped or bypassed.

---

## AspectaHighErrorRate

`aspecta:http_request_error_ratio:rate5m > 0.05` for 5 minutes — more than 5 %
of requests are answered with a 5xx.

```bash
# Which route is failing?
curl -s 'https://prometheus.localtest.me/api/v1/query' \
  --data-urlencode 'query=sum by (route,status) (rate(aspecta_http_requests_total{status=~"5.."}[5m]))'

kubectl -n aspecta logs -l app.kubernetes.io/component=backend --tail=200 | grep '"status":5'
```

The backend serves from memory and has no downstream dependency, so a genuine
5xx is rare; the usual causes are a pod being OOM-killed mid-request (check
`kubectl -n aspecta describe pod` for `OOMKilled` and raise
`backend.resources.limits.memory`) or nginx returning 502 because no backend
endpoint is ready — in which case treat it as
[AspectaDeploymentUnavailable](#aspectadeploymentunavailable).

---

## AspectaHighLatency

`aspecta:http_request_latency_p95:rate5m > 0.5` for 10 minutes.

For an in-memory API, p95 above half a second is not an application problem —
it is CPU starvation. Check saturation first:

```bash
kubectl top pods -n aspecta
kubectl top nodes
# Is the autoscaler already working on it?
kubectl -n aspecta get hpa aspecta-backend
```

If the HPA is scaling and the nodes have headroom, this resolves itself. If the
HPA is pinned at maximum, see
[AspectaAutoscalerAtMaximum](#aspectaautoscaleratmaximum). If the nodes are
saturated, the cluster is too small for the load — add a worker to
`clusters/kind/cluster.yaml`.

---

## AspectaPodRestartingTooOften

More than 3 restarts in 15 minutes.

```bash
kubectl -n aspecta get pods -o wide
kubectl -n aspecta logs <pod> --previous
kubectl -n aspecta describe pod <pod> | grep -A5 'Last State'
```

`OOMKilled` means the memory limit is too low for the traffic — raise
`resources.limits.memory` in `charts/aspecta/values.yaml` and push. An exit code
with a start-up error in the logs usually means a bad ConfigMap value: the
backend fails loudly on a malformed catalogue or an unparseable setting rather
than starting in a degraded state.

A liveness probe killing a healthy process is worth ruling out: the probe hits
`/healthz` on the operations port, which reports process health only and stays
green while the pod drains, precisely so this cannot happen during a shutdown.

---

## AspectaAutoscalerAtMaximum

An HPA has been at `maxReplicas` for 15 minutes. Not an outage — a capacity
warning that arrives before the latency alert does.

```bash
kubectl -n aspecta describe hpa aspecta-backend
kubectl top pods -n aspecta
```

Decide which is true:

- **The load is real.** Raise `autoscaling.maxReplicas` in
  `charts/aspecta/values.yaml`, and check the cluster has room for the pods.
- **The load is not real.** A traffic generator, a scraper or a retry loop.
  Check the request rate by route in the Grafana dashboard.

---

## AspectaCatalogueRevisionMismatch

Replicas report more than one build version for 15 minutes — a rollout is stuck
half-finished, so users are getting inconsistent behaviour depending on which
pod answers.

```bash
kubectl -n aspecta rollout status deployment/aspecta-backend
kubectl -n aspecta get rs -l app.kubernetes.io/component=backend
make status
```

With `maxUnavailable: 0` a rollout stalls rather than breaking the service, so
there is time to work out why the new ReplicaSet cannot become ready — almost
always a failing readiness probe or an unschedulable pod. Fix the cause, or
revert the release commit.

---

## AspectaMaintenanceModeLeftOn

`aspecta_maintenance_mode == 1` for 30 minutes — someone drained a replica
through the admin endpoint and did not turn it back on. The replica is out of
the Service endpoints but still consuming resources.

```bash
# The drain control is on the operations port, not the Ingress: it acts on one
# replica, so it has to be addressed as one replica. Pick the pod, forward the
# port, then post to it.
kubectl -n aspecta get pods -l app.kubernetes.io/component=backend

kubectl -n aspecta port-forward pod/<pod> 9090:9090 &
curl -X POST http://127.0.0.1:9090/internal/maintenance \
  -H "X-Aspecta-Token: $(make -s admin-token)" \
  -d '{"enabled":true}'

# and to undo it, against the same pod
curl -X POST http://127.0.0.1:9090/internal/maintenance \
  -H "X-Aspecta-Token: $(make -s admin-token)" \
  -d '{"enabled":false}'
```

The flag is in-process, not persisted: deleting the pod also clears it. If the
alert persists after both, find which replica is reporting:

```bash
curl -s 'https://prometheus.localtest.me/api/v1/query' \
  --data-urlencode 'query=aspecta_maintenance_mode == 1'
```

---

## Watchdog

Fires continuously, by design, and is routed to a null receiver. It is the
dead-man's switch: if `Watchdog` ever *stops* arriving at the receiver, the
alerting pipeline itself is broken and no other alert can be trusted. Never
silence it and never route it to a human.

---

## AspectaErrorBudgetBurningFast

The service is spending its error budget more than 14x faster than the
objective allows. At this rate the whole budget is gone in about two days.

This is the page-now alert. It fires only when a 1-hour window **and** a
5-minute window both agree, so it means errors are elevated *and* still
happening right now — not that something broke an hour ago and recovered.

```bash
# what is failing, and on which route
curl -s --cacert .tls/aspecta-ca.crt \
  'https://prometheus.localtest.me/api/v1/query' \
  --data-urlencode 'query=sum by (route, status) (rate(aspecta_http_requests_total{namespace="aspecta", status=~"5.."}[5m]))'

kubectl -n aspecta logs -l app.kubernetes.io/component=backend --tail=100 | grep -v '"status":2'
```

Then the usual question: did something change? `make status` shows the Argo CD
revision, and the **Running versions** table on the dashboard shows whether a
rollout is half-finished. If a deploy caused it, roll the chart back — self-heal
will restore git state, so the fix has to be a commit.

If the errors are real but expected (a dependency is down and the service is
correctly returning 503), silence the alert for the incident rather than
letting it page repeatedly.

---

## AspectaErrorBudgetBurningSlow

6x burn sustained over six hours. Not an outage — too slow to page on, too fast
to ignore, because the budget will not survive the window at this rate.

Same investigation as the fast burn above, but there is time to do it properly.
The usual cause is a single route failing a fraction of requests rather than a
general outage, so start by splitting the error rate by route.

---

## AspectaErrorBudgetExhausted

The error budget for the window is fully spent.

Nothing is on fire — this alert is a policy signal, not a failure. By the
objective's own terms it is the point at which feature releases stop and
reliability work takes priority until the window rolls forward and the budget
refills.

The number to look at is **Error budget remaining** on the dashboard. If the
objective itself is wrong — the target is stricter than the service needs to be
— that is a decision to change `monitoring.prometheusRule.slo.availabilityTarget`
in `charts/aspecta/values.yaml`, not something to silence. Changing it there
updates the recording rules, the alerts and the dashboard together.

---

## TLS and certificates

Not an alert, but the failure mode most likely to be mistaken for an outage: the
service is healthy and the browser refuses to open it.

```bash
make certs        # every Certificate, its Ready state, renewal and expiry
make trust-ca     # install the environment CA into the system trust store
```

| Symptom | Cause | Fix |
|---|---|---|
| Browser warns about the certificate | The environment CA is not trusted on this machine | `make trust-ca`, then restart the browser. Firefox has its own store and must be pointed at `.tls/aspecta-ca.crt` by hand — the command prints the steps. |
| `curl: (60) SSL certificate problem` | Same cause | `make trust-ca`, or pass `--cacert .tls/aspecta-ca.crt`. Never `-k`: it hides the one thing worth seeing. |
| nginx serves "Kubernetes Ingress Controller Fake Certificate" | The Ingress has no `tls:` block, or its Secret does not exist yet | `kubectl -n <ns> get ingress <name> -o yaml` and check `spec.tls`; then `kubectl -n <ns> describe certificate` for why it has not been issued. |
| A `Certificate` stays not `Ready` | Usually the `aspecta-ca` `ClusterIssuer` is not ready | `kubectl get clusterissuer aspecta-ca -o yaml`, then `kubectl -n cert-manager logs deploy/cert-manager`. Resolves itself once sync wave 1 has completed. |
| A host redirects to `https` even after TLS is deliberately removed | HSTS is cached in the browser for a year | Clear the host's entry at `chrome://net-internals/#hsts`. |

To rotate the CA and re-sign every leaf certificate from a new root:

```bash
kubectl -n cert-manager delete secret aspecta-ca-root
rm -f .tls/aspecta-ca.crt
# cert-manager mints a new root and re-issues every certificate that chains to it
make trust-ca
```

Every operator then has to trust the new CA — which is exactly why the root is
issued with a ten-year lifetime and the leaves with ninety days.
