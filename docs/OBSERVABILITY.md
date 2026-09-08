# Observability

What is collected, by what, and where to look.

## Components

| Piece | Lives in | Reconciled by |
|---|---|---|
| VictoriaMetrics stack (VM operator, vmsingle, vmagent, vmalert, Grafana) | `gitops/monitoring/values.yaml` | `monitoring` Application |
| Grafana dashboards (ConfigMaps) | `gitops/monitoring/dashboards/` | `dashboards` Application |
| **Alerting rules (VMRule)** | `gitops/monitoring/alerts/` | `alerts` Application |
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
| `version` | **the Git SHA** | `6dc4cff` |
| `release_color` | blue/green colour | `blue` |

`version` here is the release key that everything else in this system speaks:
the image tag, the rollback workflow's `ROLLBACK_TARGET_TAG`, and the
label-sync CronJob.

### Producer 2 — the scrape (relabelConfigs in the chart)

| Label | Value | Example |
|---|---|---|
| `pod_hash` | pod-template hash | `68c4fddbff` |
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

# ALERTING

Rules live in `gitops/monitoring/alerts/shopfast-release.yaml` as a `VMRule`,
reconciled by the `alerts` Application and evaluated by the vmalert instance the
monitoring stack already runs. No extra pods, storage or AWS spend.

## What "firing" means here — read this before relying on it

`gitops/monitoring/values.yaml` runs vmalert with `notifier.blackhole: "true"`
and `alertmanager.enabled: false` (Tier 1: no receiver). So a firing alert is
**visible but not pushed**:

| Where | Firing alert appears? |
|---|---|
| vmalert API `/api/v1/rules`, `/api/v1/alerts` | yes |
| Grafana (vmalert datasource, `ALERTS{...}` in PromQL) | yes |
| Slack / PagerDuty / email | **no — nothing is sent** |

Confirmed by the chart's own always-on `Watchdog` rule, which reports
`state: "firing"` with a populated `alerts[]` array through this exact
configuration.

**These are alerts you have to look at, not alerts that find you.** Turning them
into real notifications is one change: enable `alertmanager` in the values file,
drop the `notifier.blackhole` flag, and configure a receiver.

## Selection

vmalert runs with `selectAllByDefault: true`, so any `VMRule` in a watched
namespace is picked up with **no label matching required**. Verified: 34
chart-shipped rules are `operational` through the same mechanism. If a rule ever
fails to appear, suspect the CRD or the Application sync, not a selector.

## The rules

All five group by release, and every expression was executed against the live
vmsingle before being committed.

| Alert | Signal | Threshold | For | Severity |
|---|---|---|---|---|
| `ShopFastReleaseHighErrorRate` | 5xx ratio by version | > 5% | 10m | critical |
| `ShopFastReleaseHighClientErrorRate` | 4xx ratio by version | > 25% | 15m | warning |
| `ShopFastTargetsDown` | scrape targets down | any | 5m | critical |
| `ShopFastNoMetrics` | `absent(up)` | — | 10m | critical |
| `ShopFastReleaseGCSaturation` | `jvm_gc_overhead` | > 0.3 | 15m | warning |
| `ShopFastReleaseErrorLogSpike` | ERROR logs/sec | > 1 | 10m | warning |

Why these, per the golden signals — **alert on symptoms users feel, and every
alert needs an action**:

- **Errors** is the promote/abort criterion, and it names the offending SHA in
  the annotation so the action is unambiguous.
- **4xx separately**, because a release that 404s routes the previous one served
  is broken while erroring nothing.
- **Availability** is split in two on purpose. `up == 0` catches pods that fail;
  `absent(up)` catches the scrape disappearing entirely — a case where an
  `up == 0` rule has no series to be zero and goes quiet exactly when things are
  worst.
- **Saturation** uses `jvm_gc_overhead` (fraction of wall time in GC), not CPU%
  — CPU pages people for a JIT warm-up. Live baseline is `0.00002`, so the 0.3
  threshold has three orders of magnitude of headroom.
- **Error logs** catch failures that never reach an HTTP status: a failing
  scheduled job, or an exception swallowed before the response is written.

## THE PRECEDENCE TRAP — an alert that fires forever

This one was caught by querying the live store, not by review, and it is the
inverse of every other trap in this document: instead of never firing, the rule
never *stops*.

**PromQL binds `or` looser than the comparison operators.** So a zero-fallback
written the obvious way:

```promql
A or 0 * B > 1
```

parses as `A or (0 * B > 1)`. The threshold is applied **only to the fallback**,
never to `A`. `A` is then returned whenever it has any series at all. Verified
live, with a real error rate of zero against a `> 1` threshold:

```
A or B > 1      ->  {version="6dc4cff"} = 0     0 is not > 1 — WRONG
(A or B) > 1    ->  []                          correct
```

An alert shipped that way fires from the moment it lands, permanently, while
looking entirely reasonable in review. That burns trust in every other rule
beside it.

**Always parenthesise the whole expression before the comparison:**
`(A or B) > N`. `scripts/verify-gitops-manifests.sh` check 10 enforces this.

## The guard

Check 10 in `scripts/verify-gitops-manifests.sh` grades every committed VMRule,
in the `security` stage, before any AWS resource is touched. It refuses:

1. `http_server_requests_seconds_bucket` — buckets that do not exist
2. `up{}` selected by an application label — matches nothing, even in an outage
3. an unparenthesised zero-fallback comparison — fires forever

and warns when a version-grouped rule does not pin `job="shopfast"`
(preview-Service double-counting).

Comments are stripped before grading, because these files document the traps in
prose and a guard that trips over its own explanation is a broken guard.

## Verifying a rule actually works

`inactive` is indistinguishable from healthy, so silence proves nothing. Test
both directions against the live store — invert the threshold and confirm the
rule *can* return the labelled series:

```
(expr) > 5     ->  []                              inactive when healthy
(expr) > -1    ->  {version="6dc4cff",...} = 0     fires when crossed
```

Then confirm vmalert loaded it:

```
kubectl -n monitoring get vmrule shopfast-release
kubectl -n monitoring exec deploy/vmalert-vm -c vmalert -- \
  wget -qO- http://127.0.0.1:8080/api/v1/rules
```

`health: "ok"` with a non-empty `lastEvaluation` means it is being evaluated. A
rule with `lastError` set is being evaluated and failing — different problem,
visible in the same place.

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
job the Argo CD console shows `1.0.0` while pods run the real SHA.

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

---

## imagePullPolicy is `Always`

Both values files set `image.pullPolicy: Always`.

In the normal case this changes nothing: tags are unique Git SHAs, so the image
is never already on the node and both policies pull identically. The difference
appears only when a tag is **reused or moved** — a rebuild of the same SHA after
an ECR lifecycle expiry, a manually retagged image, or a rollback to a tag whose
content changed.

With `IfNotPresent`, a node that already cached that tag keeps serving the
**old layers** while `kubectl describe` reports the new tag. The pod lies about
what it is running, and nothing errors.

That is the failure this system is least able to tolerate: the version label,
every dashboard, and the rollback workflow all assume the tag identifies the
bits. The cost of `Always` is one registry HEAD request per pod start — ECR is
in-region and the layers are already cached, so no bytes move on a match.

Kubernetes' Configuration Best Practices names the `:latest` + `IfNotPresent`
combination explicitly. The chart guards already refuse `latest`; this closes
the other half.
