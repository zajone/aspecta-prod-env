# Architecture

This document covers the parts of the design that do not fit in the README: why
each boundary is where it is, what the alternatives were, and what the design
does *not* do.

## Components

| Namespace | Workload | Replicas | Purpose |
|---|---|---|---|
| `aspecta` | `aspecta-frontend` | 2–4 (HPA) | serves the static UI, reverse-proxies `/api/` to the backend |
| `aspecta` | `aspecta-backend` | 2–6 (HPA) | catalogue API on `:8080`, operations surface on `:9090` |
| `ingress-nginx` | `ingress-nginx-controller` | 1 | the single ingress point, on host ports 80/443 |
| `monitoring` | Prometheus, Alertmanager, Grafana, kube-state-metrics, node-exporter | 1 each | metrics, alerting, dashboards |
| `kube-system` | `metrics-server` | 1 | resource metrics for the HPAs |
| `argocd` | Argo CD controller, repo-server, API server, redis | 1 each | reconciles the cluster against git |

## Namespace boundaries

Namespaces are the unit of isolation here, and each one has a different Pod
Security Admission level because the components genuinely differ:

| Namespace | PSA enforce | Why |
|---|---|---|
| `aspecta` | `restricted` | the workloads need nothing: non-root, no capabilities, read-only root filesystem |
| `monitoring` | `privileged` | node-exporter must mount `/proc`, `/sys` and the host root filesystem |
| `ingress-nginx` | `privileged` | the Baseline standard forbids `hostPort` outright, and the controller binds host ports 80 and 443 - which is how traffic reaches a kind cluster at all. `audit` and `warn` stay at `baseline`, so any other deviation is still recorded. |
| `argocd` | `baseline` | audited and warned at `restricted`, enforced at `baseline` for upgrade headroom |

Enforcing `restricted` on `aspecta` means the API server would reject a
privileged pod there even if a manifest asked for one — the cluster-side
counterpart to the `securityContext` in the chart. `make verify-security`
asserts that rejection rather than assuming it.

## Ports, and why there are two

The backend listens on two ports with two separate routers:

```
:8080  public    /api/v1/*            reachable from the frontend pods only
:9090  ops       /healthz /readyz     reachable from the monitoring namespace
                 /metrics             and from the kubelet
                 /internal/alerts
```

A single port would have meant one of two compromises: expose `/metrics` and
the Alertmanager webhook to anything that can reach the API, or restrict the
API to the monitoring namespace as well. Splitting them lets the NetworkPolicy
be precise — `:8080` from frontend *pods*, `:9090` from the monitoring
*namespace* — and keeps scrape and probe traffic out of the application access
log entirely, because the request-logging middleware is only mounted on the
public router.

## Configuration flow

```
ConfigMap  ─ envFrom ──→ backend   (APP_BANNER, LOG_LEVEL, PAGE_SIZE_*, FEATURE_SEARCH, ...)
           ─ env ──────→ frontend  (BACKEND_ADDR → substituted into the nginx server block)
Secret     ─ envFrom ──→ backend   (ADMIN_TOKEN, optional: true)
```

The frontend's nginx configuration is a template in the image, rendered by the
image's own entrypoint from `BACKEND_ADDR` at start-up. That keeps the Service
name out of the image while avoiding a second copy of the nginx config in the
chart.

Both Deployments carry `checksum/config`, a hash of the rendered ConfigMap. A
value change therefore rolls the pods; a bare `envFrom` reference alone would
leave them running with stale configuration until something else happened to
restart them. The Secret is deliberately *not* in the checksum: it is managed
outside git, and hashing it would make the Deployment's desired state depend on
a value Argo CD cannot see.

## Availability

| Mechanism | Setting | What it buys |
|---|---|---|
| Replicas | min 2 per component | no single-pod service |
| `topologySpreadConstraints` | `maxSkew: 1` over `kubernetes.io/hostname`, `ScheduleAnyway` | replicas land on different nodes; a single-node cluster still schedules |
| `PodDisruptionBudget` | `minAvailable: 1` | a node drain cannot take the last replica |
| Rolling update | `maxUnavailable: 0`, `maxSurge: 1` | capacity added before old pods retire |
| Graceful shutdown | readiness flipped, `DRAIN_DELAY`, then `Shutdown()` | in-flight requests finish; no 502 during a rollout |
| Probes | `startupProbe` + separate liveness and readiness | slow start does not trip liveness; draining does not either |

`ScheduleAnyway` rather than `DoNotSchedule` is a deliberate choice: with three
nodes and up to six replicas, a hard constraint would leave pods `Pending` at
the top of the autoscaling range for no availability benefit.

## Data flow of an alert

```
Prometheus                 evaluates the PrometheusRule from charts/aspecta
   │  alert fires
   ▼
Alertmanager               groups by alertname+namespace+severity,
   │                       inhibits warnings under an open critical,
   │                       routes Watchdog to /dev/null
   │  webhook POST
   ▼
backend :9090              /internal/alerts — allowed by the backend
   │                       NetworkPolicy from the monitoring namespace only
   │  in-memory, bounded
   ▼
frontend UI                GET /api/v1/alerts, refreshed every 15 s
```

The alert store is intentionally ephemeral. Alertmanager is the source of truth
and re-sends firing alerts every group interval, so a restarted pod repopulates
itself within a minute — and the application never becomes a system of record
for something it does not own.

## What this design does not do

- **No service mesh.** With two services and one call between them, mTLS and
  traffic shifting would add far more operational surface than they remove.
  TLS is terminated at the ingress and NetworkPolicies cover the isolation
  requirement; where that line sits, and what moves it, is in
  [`security.md`](security.md#where-tls-stops-and-why).
- **No database.** The dataset is embedded, which is what makes "stateless"
  a fact rather than an aspiration. A real product would add one, and with it a
  StatefulSet or a managed service, connection pooling, migrations as a Helm
  hook or an Argo CD PreSync hook, and a backup story.
- **No canary or blue/green.** A rolling update with `maxUnavailable: 0` is the
  right default for a service with no schema and no state. Argo Rollouts would
  be the next step if traffic-shaped releases were needed.
- **No multi-cluster.** The `cluster` external label on Prometheus and the
  parameterised repository URL in the app-of-apps are the two hooks that would
  make it possible.
