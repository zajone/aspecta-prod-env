# Security

Every control below is asserted against the running cluster by
`make verify-security`, and the assertions include the negative cases. A control
that is only described is a control nobody has tested.

## Threat model

What this environment is designed to contain, in order of likelihood:

1. **A compromised application container.** The most likely single event. The
   goal is that a shell inside the backend or frontend yields nothing: no
   cluster credential, no writable filesystem, no ability to escalate, no
   outbound network, and no reachable neighbours.
2. **A compromised or careless operator account.** Someone with `kubectl`
   access to the namespace should not be able to read production credentials or
   affect any other namespace.
3. **An eavesdropper on the network between a browser and the cluster.**
   Credentials for Argo CD and Grafana, and the application's admin token, all
   travel over this path. Nothing may be served in plaintext — see
   [section 5](#5--tls).
4. **A malicious or broken change in git.** The delivery path must not be able
   to widen its own privileges — a chart that suddenly declares a ClusterRole
   should fail, not apply.
5. **A vulnerable dependency or base image.** Caught before publication, with
   the image traceable back to the commit that produced it.

Explicitly out of scope: a compromised node or control plane, and a compromised
GitHub account.

## 1 — Container hardening

```yaml
# pod
runAsNonRoot: true
runAsUser: 65532          # distroless nonroot (frontend: 101, nginx)
seccompProfile:
  type: RuntimeDefault
automountServiceAccountToken: false

# container
allowPrivilegeEscalation: false
privileged: false
readOnlyRootFilesystem: true
capabilities:
  drop: [ALL]
```

The read-only root filesystem is real, not nominal: every path nginx writes to
at runtime (`/etc/nginx/conf.d` for the rendered config, `/var/cache/nginx`,
`/tmp`) is an explicit `emptyDir` with `medium: Memory` and a size limit. The
backend needs only `/tmp`.

The base images do the heavy lifting. `gcr.io/distroless/static-debian12:nonroot`
contains no shell, no package manager and no libc, so most post-exploitation
tooling simply has nothing to run; `nginxinc/nginx-unprivileged` already listens
on 8080 as uid 101 and keeps its pid file in `/tmp`, so no entrypoint patching
is needed to satisfy the constraints above.

The `aspecta` namespace enforces the `restricted` Pod Security Standard, so all
of this is also enforced by the API server rather than only requested by the
chart.

## 2 — RBAC

### The workloads

Neither workload talks to the Kubernetes API, so:

- their ServiceAccount has **no Role or ClusterRole bound to it**, and
- `automountServiceAccountToken: false` is set on both the ServiceAccount and
  the pod specs, so no token is projected into the filesystem at all.

```console
$ kubectl auth can-i get pods -n aspecta --as=system:serviceaccount:aspecta:aspecta
no
$ kubectl auth can-i list secrets -n aspecta --as=system:serviceaccount:aspecta:aspecta
no
```

### The humans

Two **namespace-scoped** Roles, bound to ServiceAccounts so the restriction can
be demonstrated without issuing client certificates. Bind them to real users or
groups through `rbac.viewer.subjects` and `rbac.operator.subjects`.

| | `aspecta-viewer` | `aspecta-operator` |
|---|---|---|
| read pods, services, endpoints, configmaps, events | yes | yes |
| read pod logs | yes | yes |
| read deployments, replicasets, HPAs, ingresses, netpols | yes | yes |
| delete a pod | no | yes |
| patch a Deployment, scale it | no | yes |
| **read Secrets** | **no** | **no** |
| create or delete a Deployment | no | **no** |
| anything at all in another namespace | no | no |

Two of those rows are the interesting ones.

**Neither role can read a Secret.** The usual failure mode of a "read-only"
role is that `get secrets` turns it into full compromise, because service
account tokens and application credentials live there. On-call needs logs and
events, not the admin token.

**Neither role can create or delete a Deployment.** The desired state comes from
git; Argo CD would revert a hand-created object within the reconciliation
window. Granting a permission whose effect is undone three minutes later teaches
people that the permission does not work — better to be explicit that the
create path is a pull request.

### Argo CD

A third layer, at the delivery boundary. Two `AppProject`s with deliberately
different privileges:

- **`platform`** — installs cluster infrastructure, so it needs cluster-scoped
  permissions. They are enumerated rather than wildcarded: `Namespace`, `CRD`,
  `ClusterRole(Binding)`, the two webhook configurations, `IngressClass`,
  `APIService`, `PriorityClass`. Destinations are limited to four namespaces.
- **`aspecta`** — the application. One source repository, one destination
  namespace, `clusterResourceWhitelist: []` (not one cluster-scoped object), and
  `Secret`, `ResourceQuota` and `LimitRange` explicitly blacklisted.

The effect is that a change to the application chart that tried to create a
`ClusterRoleBinding` or a `Secret` **fails the sync** instead of being applied.
That is the control for threat 3: the delivery path cannot widen its own
privileges.

Argo CD's own API is also restricted — `configs.rbac` in
`platform/argocd/values.yaml` sets `policy.default: role:readonly`, so an
authenticated user can look but not sync or delete.

## 3 — Network isolation

Three policies in the `aspecta` namespace, deny-first:

| Policy | Selector | Ingress | Egress |
|---|---|---|---|
| `aspecta-default-deny` | **every pod** | denied | denied |
| `aspecta-frontend` | frontend pods | `ingress-nginx` namespace → `:8080` | kube-dns `:53`; backend pods `:8080` |
| `aspecta-backend` | backend pods | frontend **pods** → `:8080`; `monitoring` **namespace** → `:9090` | **none at all** |

Three properties are worth calling out.

**The default-deny policy selects every pod, not just the known ones.** A pod
someone adds to the namespace later is denied by default rather than inheriting
whatever the existing policies happen to allow. `make verify-security` proves
this by launching an unlabelled pod *inside* the namespace and confirming it
cannot reach the backend — being in the right namespace is not a credential.

**The backend has no egress rules whatsoever.** Not even DNS. The catalogue is
compiled into the binary, so the service has no legitimate reason to open an
outbound connection, and after a compromise every exfiltration attempt is
dropped by the CNI. This is the strongest statement a NetworkPolicy can make,
and it is only available because the application was designed to have no
dependencies.

**Cross-namespace access is granted per namespace and per port**, using the
`kubernetes.io/metadata.name` label the API server maintains — so `monitoring`
can reach `:9090` and nothing else, and no other namespace can reach anything.

Enforcement depends on the CNI. kindnet in current kind releases enforces
NetworkPolicy; the verification script does not take that on trust, it sends
real traffic and requires it to be blocked. If a CNI ever needs kubelet probes
allowed explicitly, `networkPolicy.kubeletProbes` exists for that — scoped to a
node CIDR, never to `0.0.0.0/0`, which would silently reopen the ports to every
pod in the cluster.

## 4 — Secrets

**No credential is committed, and the application chart renders zero Secret
objects** — asserted by `make verify-security` and in CI.

`scripts/bootstrap.sh` generates a random admin token and a random Grafana
password on the machine and creates the Secrets with `kubectl` before Argo CD
runs. Re-running the bootstrap does not rotate them.

The consuming container declares the Secret **optional**:

```yaml
envFrom:
  - secretRef:
      name: aspecta-admin
      optional: true
```

A cluster without the Secret therefore starts normally and the privileged
endpoint returns `501 admin_disabled`. It fails **closed**, and it does not fail
to start — the two properties that matter for a credential that is delivered out
of band.

### The production upgrade path

Bootstrap-generated secrets are right for a local environment and wrong for a
real cluster, where the token should come from a vault. The chart already
accepts that:

```yaml
secret:
  create: false
  existingSecret: aspecta-admin
```

so the whole migration is to have something else produce a Secret of that name.
With the External Secrets Operator:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: aspecta-admin
  namespace: aspecta
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: aspecta-admin          # the name the chart already references
  data:
    - secretKey: ADMIN_TOKEN
      remoteRef:
        key: aspecta/production
        property: admin_token
```

Sealed Secrets is the other reasonable answer — an encrypted `SealedSecret`
*can* live in git, which keeps a single source of truth at the cost of a
cluster-bound key. Either is a drop-in; nothing else in the chart changes.

Note that rotating the Secret does not roll the pods, because it is not part of
`checksum/config`. On a real cluster, Reloader or an ESO-triggered rollout
closes that gap.

## 5 — TLS

Nothing in this environment is served over plain HTTP. Three separate mechanisms
have to agree for that to stay true, so that relaxing any one of them does not
silently open a plaintext route:

| Control | Where | What it does |
|---|---|---|
| `force-ssl-redirect: "true"` controller-wide | [`platform/ingress-nginx/values.yaml`](../platform/ingress-nginx/values.yaml) | Every host redirects to `https`, *including* one whose Ingress has no `tls:` block. An Ingress merged without TLS fails closed to a redirect instead of serving the application in the clear. |
| A `tls:` block and a `cert-manager.io/cluster-issuer` annotation on all five Ingresses | the app chart, plus the three platform values files | Each host gets its own certificate, issued and renewed without a `Certificate` object to keep in sync with the Ingress. |
| `Strict-Transport-Security: max-age=31536000` | the same controller config | After the first visit the browser refuses plaintext for that host on its own, so the redirect stops being load-bearing. |

`includeSubDomains` is deliberately **off**: these hostnames sit under the shared
public suffix `localtest.me`, and asserting HSTS for every subdomain of it would
apply this cluster's policy to hosts it does not own.

TLS 1.0 and 1.1 are refused outright rather than deprioritised, the cipher list
is explicit (forward secrecy and AEAD only, so an upstream default change cannot
widen it), and session tickets are off.

### The certificate authority

cert-manager runs a private CA, generated in the cluster and signed by itself:

```
selfsigned-bootstrap (ClusterIssuer)
  └── aspecta-ca (Certificate, isCA, in namespace cert-manager)
        └── aspecta-ca (ClusterIssuer)
              ├── aspecta-tls          aspecta.localtest.me
              ├── argocd-server-tls    argocd.localtest.me
              ├── grafana-tls          grafana.localtest.me
              ├── prometheus-tls       prometheus.localtest.me
              ├── alertmanager-tls     alertmanager.localtest.me
              └── default-wildcard-tls *.localtest.me — what ingress-nginx
                                       serves for a Host matching no Ingress,
                                       instead of its built-in fake certificate
```

A private CA rather than Let's Encrypt because `*.localtest.me` resolves to
`127.0.0.1` and can never pass an ACME HTTP-01 or DNS-01 challenge. The
mechanism is otherwise identical to a public deployment — the same `Certificate`
objects, the same ingress-shim annotations, the same renewal at two thirds of
lifetime — so the migration is one field: point the annotations at an ACME
`ClusterIssuer` instead of `aspecta-ca`.

The CA private key never leaves the cluster. The CA *certificate* is public by
definition, and `make trust-ca` installs it into the operator's trust store,
which is what lets `make verify` validate the real chain rather than skipping
verification with `curl -k`. Certificate expiry is a Prometheus metric
(`certmanager_certificate_expiration_timestamp_seconds`), so it is alertable
rather than something a browser warning discovers.

### Where TLS stops, and why

TLS terminates at the ingress controller. From there to the pod — and between
pods — traffic is plaintext:

- ingress-nginx → frontend `:8080`
- frontend → backend `:8080`
- Prometheus → backend `:9090`
- Alertmanager → backend `:9090/internal/alerts`
- ingress-nginx → argocd-server (which runs with `server.insecure: true`
  precisely so it does not terminate TLS a second time)

That traffic never leaves the node, and it is already constrained by the
default-deny NetworkPolicies in [section 3](#3--network-isolation): a pod that
is not explicitly allowed cannot open the connection at all, encrypted or not.
Encrypting it as well is a service mesh's job, not something to hand-roll across
five Ingress objects and a dozen Services — the cost is a sidecar per pod and a
second CA to operate, and the threat it addresses (an attacker already able to
sniff the node's own network) is out of this environment's scope, alongside a
compromised node.

The line moves when the cluster becomes multi-tenant or spans a network the
operator does not control. At that point the answer is Linkerd or Istio in mTLS
mode, and the certificates above stay exactly as they are.

## 6 — Application-level controls

Delivered by the code, not by the platform:

- **The admin endpoint fails closed.** With no token configured it returns
  `501`, never an open endpoint. The comparison is
  `crypto/subtle.ConstantTimeCompare`, so it does not leak the token through
  response timing.
- **Bounded request bodies.** Every handler reads through
  `http.MaxBytesReader`, capped at 256 kB.
- **Strict decoding where we own the schema.** `DisallowUnknownFields` on the
  admin endpoint, so a typo in a client payload is a `400` rather than a
  silently ignored field. Lenient decoding for the Alertmanager webhook, whose
  schema belongs to someone else and is free to grow.
- **Server timeouts.** `ReadHeaderTimeout`, `ReadTimeout`, `WriteTimeout` and
  `IdleTimeout` are all set, so a slow client cannot hold a connection open
  indefinitely.
- **Bounded cardinality in metrics.** The `route` label is the registered
  pattern, never the raw path, so a scanner hitting random URLs cannot create
  unbounded time series.
- **Security headers** on every response, from both the API
  (`Content-Security-Policy: default-src 'none'`) and nginx. The UI ships no
  third-party asset, so its policy can forbid every external origin outright —
  there is no `unsafe-inline` and no CDN to allow.
- **No secrets in logs.** Logging is structured (`log/slog`, JSON) and logs
  method, path, status, duration and a request ID — never headers or bodies.

## 7 — Supply chain

| Control | Where |
|---|---|
| Base images pinned by digest, not tag | `apps/*/Dockerfile` |
| Actions pinned to a commit SHA, not a tag | `.github/workflows/*.yaml` |
| Pinned upstream Helm charts | `gitops/root/values.yaml`, `scripts/bootstrap.sh` |
| Pinned CLI tool versions | `scripts/install-tools.sh` |
| Multi-stage build, no build tools in the runtime image | `apps/backend/Dockerfile` |
| Vulnerability gate | Trivy in `ci.yaml`, `exit-code: 1` on HIGH/CRITICAL |
| Misconfiguration scan | Trivy `scan-type: config` in `pr.yaml` |
| SBOM | `sbom: true` on the build, attached to the image |
| Build provenance | `actions/attest-build-provenance`, pushed to the registry |
| No long-lived registry credential | GHCR is authenticated with the workflow's own `GITHUB_TOKEN` |
| CI cannot reach the cluster | the pipeline's only write target is git |

That last row is the important one. The pipeline holds no kubeconfig and no
cluster credential; it changes git, and Argo CD changes the cluster. A
compromised workflow can propose a bad state, which is visible in `git log` and
revertible with `git revert` — it cannot silently apply one.

## Verifying all of it

```bash
make verify-security
```

Asserts, against the live cluster: the workload identity has no API access and
no projected token; both operator roles are scoped and cannot read Secrets or
reach another namespace; a privileged pod is rejected by the API server; a pod
in another namespace cannot reach the frontend, the API or the metrics port; an
unlabelled pod inside the namespace cannot either; egress to the internet is
denied; the chart renders no Secret — while confirming that the paths which must
work (Ingress → frontend → backend, and Prometheus → `:9090`) still do.

`make verify` covers the TLS half: that the CA `ClusterIssuer` is ready, that
every host presents a certificate which chains to the environment CA and matches
its hostname, that port 80 answers with a `308` to `https` on every host, that
TLS 1.0 and 1.1 are refused, and that HSTS is set.
