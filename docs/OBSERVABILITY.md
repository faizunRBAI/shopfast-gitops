# Observability

What is collected, by what, and where to look.

## Components

| Piece | Lives in | Reconciled by |
|---|---|---|
| VictoriaMetrics stack (VM operator, vmsingle, vmagent, vmalert, Grafana) | `gitops/monitoring/values.yaml` | `monitoring` Application |
| Grafana dashboards (ConfigMaps) | `gitops/monitoring/dashboards/` | `dashboards` Application |
| App metrics scrape | `application/helm/shopfast/templates/servicescrape.yaml` | `shopfast` Application (Helm) |
| Control-plane metrics | `gitops/observability-controllers/` | `observability-controllers` Application |
| Console version label | `gitops/label-sync/` | `label-sync` Application |

## The monitoring Application is multi-source

`gitops/apps/children/monitoring.yaml` uses two sources: the upstream chart
from `victoriametrics.github.io/helm-charts`, and this repository referenced as
`$values` for `gitops/monitoring/values.yaml`.

This matters operationally. CI rewrites the Grafana certificate ARN
(`scripts/set-grafana-cert.py`). With inline values that rewrite had to edit the
Application manifest itself, which coupled "which chart version" to "what
config" and produced a stale-ARN deadlock. With `$values` the rewrite targets a
plain values file and the Application object is left alone.

---

# THE LABEL CONTRACT

**Read this before writing any PromQL against this stack.** Every label below
was verified against both the live store and the pod's raw
`/actuator/prometheus` output. A wrong label name in PromQL is not an error —
it returns "No data" and looks exactly like an idle or broken system.

Two independent producers attach labels, and **they must never write the same
label name.**

### Producer 1 — the application (Micrometer common tags)

Declared in `application/src/main/resources/application.yml` under
`management.metrics.tags`. Present on **every metric the app exposes**:

| Label | Value | Example |
|---|---|---|
| `application` | constant | `shopfast` |
| `version` | **the Git SHA** | `5274b56` |
| `release_color` | blue/green colour | `blue` |

`version` here is the release key that everything else in this system speaks:
the image tag, the rollback workflow's `ROLLBACK_TARGET_TAG`, and the
label-sync CronJob.

### Producer 2 — the scrape (relabelConfigs in the chart)

| Label | Value | Example |
|---|---|---|
| `pod_hash` | pod-template hash | `64d7d69bb5` |
| `strategy` | delivery strategy | `bluegreen` |

### Producer 3 — service discovery

`namespace`, `job`, `service`, `pod`, `container`, `endpoint`, `instance`.

## Two traps that cost real debugging time

### 1. `up` carries NO application tags

`up` is **synthesised by the scraper**, not exposed by the app. So it has
`pod_hash` and `strategy` but **not** `version`, `release_color` or
`application`:

```
up{application="shopfast"}   ->  EMPTY   (not an outage — a category error)
up{job="shopfast"}           ->  works
```

Any panel needing release identity must query an app metric such as
`process_uptime_seconds`, never `up`.

### 2. A relabel that targets an app-owned label CLOBBERS it

An earlier revision of the scrape wrote `targetLabel: version` with the
pod-template hash. Prometheus resolves the collision by keeping the relabel's
value and renaming the app's to `exported_version`. Observed live:

```
version="64d7d69bb5"          <- pod-template hash (relabel won)
exported_version="5274b56"    <- the real Git SHA, displaced
```

Nothing errors. Dashboards simply key on an opaque ReplicaSet hash while the
human-meaningful identifier hides in a label nobody queries — and the two
disagree about what "the release" means.

**The rule: each producer owns a distinct label name.** The scrape publishes
`pod_hash`, never `version`; it does not publish `color` either, because the app
already emits `release_color`.

### The relabel spelling (still a trap)

- The Kubernetes pod **label** is hyphenated: `rollouts-pod-template-hash`
  (Rollouts) or `pod-template-hash` (plain Deployment).
- Service discovery exposes labels as `__meta_kubernetes_pod_label_<name>` with
  every non-alphanumeric character converted to an **underscore**.

So `sourceLabels` must use underscores:
`__meta_kubernetes_pod_label_rollouts_pod_template_hash`. Written with hyphens
it matches nothing, emits an empty label, and **does not error**. Both hashes
are configured because exactly one exists depending on the strategy.

## No histogram buckets exist

```
/api/v1/series?match[]=http_server_requests_seconds_bucket  ->  []
```

Spring Boot publishes `http_server_requests_seconds` as **sum + count + max
only**. Buckets need
`management.metrics.distribution.percentiles-histogram.http.server.requests: true`,
which is not enabled.

`histogram_quantile()` over a metric that does not exist returns no series and
does not error, so p50/p95/p99 panels render permanently empty. Latency panels
here therefore show the **mean** (`sum/count`) and the observed **max**. That is
deliberate: a real mean beats a percentile the data cannot support. Enabling
buckets is an application change with a cardinality cost — worth doing when
latency SLOs are defined, not before.

## Two jobs scrape the same pods

Blue/green renders two Services, so the same pods appear under two jobs:

| Job | Service | Meaning |
|---|---|---|
| `shopfast` | active | production traffic |
| `shopfast-preview` | preview | pre-promotion validation |

Rate panels must select `job="shopfast"`. Selecting `namespace="shopfast"`
double-counts every measurement.

---

## Dashboards

ConfigMaps labelled `grafana_dashboard: "1"`, discovered by the Grafana sidecar
with `searchNamespace: ALL` and foldered via the `grafana_folder` annotation.
Editing a dashboard is a commit, not a click — a change made in the Grafana UI
is not persisted.

| Dashboard | uid | Purpose |
|---|---|---|
| ShopFast — Application | `shopfast-app` | Steady-state health: rate, errors, latency, JVM |
| ShopFast — Deployments & Rollouts | `shopfast-deploy` | Rollout phase, colour split, replicas |
| **ShopFast — Release Comparison** | `shopfast-releases` | **Per-release breakdown — the promote/abort decision** |
| Kubernetes cluster | `k8s-cluster` | Nodes, capacity |

### Release Comparison — how to read it during a rollout

This is the dashboard the scrape relabels exist for. Every golden-signal panel
groups by `version` (Git SHA), so a cutover shows **two series side by side**
instead of one blended average that hides a regression behind the healthy
release's traffic.

The promotion decision:

1. **Releases in flight** goes 1 → 2. The new SHA appears.
2. **Errors — 5xx % by version.** Compare the two lines. If the new SHA sits
   above the old one, abort. This is the criterion.
3. **Client errors — 4xx %** is separate on purpose: a release that starts
   404ing routes the previous one served is broken even though nothing errored.
4. **Latency** (mean and worst case) and **JVM heap** — compare the *slopes*,
   not absolute values; a freshly started release always starts low.
5. After promotion, the old SHA's band drains to zero over
   `blueGreen.scaleDownDelaySeconds`. **Releases in flight** returns to 1.

### The zero-fallback on ratio panels

A plain `errors/total` ratio returns **nothing** when there are no errors — the
numerator has no series to divide. On the panel that is your abort criterion,
"no data" and "zero errors" would look identical, which is the worst possible
ambiguity at exactly the wrong moment. Each ratio numerator therefore carries:

```promql
... or 0 * <the same aggregation over ALL requests>
```

which yields a genuine `0` **carrying the version label**. `or vector(0)` also
produces a zero but drops every label, collapsing the per-release breakdown into
one unlabelled line. Use `vector(0)` only on single-value aggregate panels.

---

## Control-plane metrics: why a Service is required

Neither Argo CD nor Argo Rollouts ships a Service in front of its metrics port
(the application-controller has no Service at all). A `VMServiceScrape` selects
**endpoints**, and endpoints only exist behind a Service — so a scrape on its
own collects nothing while still reporting Healthy.

Ports, all read off live pods rather than assumed:

| Component | Namespace | Port | Selector |
|---|---|---|---|
| application-controller | `argocd` | 8082 | `name=argocd-application-controller` |
| server | `argocd` | 8083 | `name=argocd-server` |
| repo-server | `argocd` | 8084 | `name=argocd-repo-server` |
| rollouts-controller | `argo-rollouts` | 8090 | `name=argo-rollouts` **+ `component=rollouts-controller`** |

### The rollouts selector needs two labels

The Rollouts **controller** and the Rollouts **dashboard** both carry
`app.kubernetes.io/name: argo-rollouts`. They differ only by
`app.kubernetes.io/component`.

Selecting on `name` alone matches both. The dashboard serves the UI on 3100 and
nothing on 8090, so it becomes a permanently failing scrape target whose
failures are attributed to the controller. Caught here only because the Service
came up with two endpoints while the controller has one replica.

### Verifying a scrape actually works

A scrape that matches nothing looks identical to a healthy one in the Argo CD
UI. The only real check is that the Service has endpoints — **and that the
endpoint count matches the replica count**:

```
kubectl -n argocd get endpoints argocd-application-controller-metrics
kubectl -n argo-rollouts get endpoints argo-rollouts-metrics
```

Empty `ENDPOINTS` means the selector matches nothing. *Too many* endpoints
means it matches too much. Cross-check the IPs against `get pods -o wide`.

## Label-sync

Helm renders `app.kubernetes.io/version` from `.Chart.AppVersion`, a constant in
`Chart.yaml`. The image tag is rewritten by CI on every build. So without this
job the Argo CD console shows `1.0.0` while pods run `5274b56`.

The CronJob runs every minute, reads the image off the live Rollout (or
Deployment), and patches the label to the real tag. It no-ops when the label is
already correct, and skips digest-pinned images, which have no tag to publish.

Its RBAC is a namespace-scoped Role: `get`/`list`/`patch` on rollouts and
deployments in `shopfast`, nothing else.

### It REQUIRES a matching ignoreDifferences entry

This is the part that is easy to miss and expensive to debug.

`selfHeal: true` means Argo CD reverts anything that differs from git. Git says
`1.0.0`. So without an exception the two writers fight, once a minute, forever:

```
:00  CronJob patches   1.0.0 -> 5274b56
:00  selfHeal reverts  5274b56 -> 1.0.0
```

Observed live at `autoHealAttemptsCount: 4` within minutes of first enabling
the job — the same failure shape as the rollouts `managed-by` annotation loop
that once reached 102 attempts.

The fix is in `gitops/apps/children/shopfast.yaml`: a scoped
`ignoreDifferences` entry for that single label, on both the Rollout and the
Deployment. Note the JSON Pointer escaping — `/` inside a key is `~1`:

```yaml
jsonPointers:
  - /metadata/labels/app.kubernetes.io~1version
```

**The general rule:** any field a runtime controller legitimately owns must be
declared in `ignoreDifferences`, or selfHeal treats every write as drift.
Rollouts owns `/spec/replicas`; label-sync owns this label. Scope it to the one
field — ignoring `/metadata/labels` wholesale would blind Argo to selector drift
it *should* catch.

### Image constraint

It needs a shell *and* kubectl, so `bitnami/kubectl` — a distroless kubectl
image has no `/bin/sh` and cannot run the script at all.

It is pinned **by digest**, not by tag, because Bitnami no longer publishes
versioned tags on the free Docker Hub tier. Verified against this cluster:

```
bitnami/kubectl:1.31.3 -> NotFound
bitnami/kubectl:1.37.0 -> NotFound
bitnami/kubectl:latest -> pulls, Client Version v1.37.0
```

`latest` is the only tag that resolves, and floating a job that runs 1440 times
a day on a mutable tag is how it breaks silently later. To refresh the digest,
pull `latest` and read back `.status.containerStatuses[0].imageID` — never write
a `sha256:` from memory.
