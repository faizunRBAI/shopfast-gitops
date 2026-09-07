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

## The version relabel — read this before editing the scrape

The app scrape maps the pod-template hash onto a `version` label so dashboards
can break metrics down per release. On a blue/green app that is the entire
point: without it, blue and green are indistinguishable in every panel.

The spelling is the trap:

- The Kubernetes pod **label** is hyphenated: `rollouts-pod-template-hash`
  (Rollouts) or `pod-template-hash` (plain Deployment).
- Prometheus service discovery exposes labels as
  `__meta_kubernetes_pod_label_<name>` with every non-alphanumeric character
  converted to an **underscore**.

So the relabel `sourceLabels` must use underscores:
`__meta_kubernetes_pod_label_rollouts_pod_template_hash`.

Written with hyphens it matches nothing, emits an empty `version` label, and
**does not error**. Both hashes are configured because exactly one exists
depending on the strategy in effect.

Labels added: `version`, `color`, `strategy`.

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

## Dashboards

ConfigMaps labelled `grafana_dashboard: "1"`, discovered by the Grafana sidecar
with `searchNamespace: ALL` and foldered via the `grafana_folder` annotation.
Editing a dashboard is a commit, not a click — a change made in the Grafana UI
is not persisted.
