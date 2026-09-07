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

| Component | Namespace | Port |
|---|---|---|
| application-controller | `argocd` | 8082 |
| server | `argocd` | 8083 |
| repo-server | `argocd` | 8084 |
| rollouts-controller | `argo-rollouts` | 8090 |

### Verifying a scrape actually works

A scrape that matches nothing looks identical to a healthy one in the Argo CD
UI. The only real check is that the Service has endpoints:

```
kubectl -n argocd get endpoints argocd-application-controller-metrics
```

An empty `ENDPOINTS` column means the selector does not match the pods. Confirm
with:

```
kubectl -n argocd get pod argocd-application-controller-0 -o jsonpath={.metadata.labels}
```

## Label-sync

Helm renders `app.kubernetes.io/version` from `.Chart.AppVersion`, a constant in
`Chart.yaml`. The image tag is rewritten by CI on every build. So without this
job the Argo CD console shows `1.0.0` while pods run `5274b56`.

The CronJob runs every minute, reads the image off the live Rollout (or
Deployment), and patches the label to the real tag. It no-ops when the label is
already correct, and skips digest-pinned images, which have no tag to publish.

Its RBAC is a namespace-scoped Role: `get`/`list`/`patch` on rollouts and
deployments in `shopfast`, nothing else.

**Image constraint:** it needs a shell *and* kubectl, so `bitnami/kubectl` —
a distroless kubectl image has no `/bin/sh` and cannot run the script at all.
The tag is pinned explicitly with `imagePullPolicy: Always`; never `latest`.

## Dashboards

ConfigMaps labelled `grafana_dashboard: "1"`, discovered by the Grafana sidecar
with `searchNamespace: ALL` and foldered via the `grafana_folder` annotation.
Editing a dashboard is a commit, not a click — a change made in the Grafana UI
is not persisted.
