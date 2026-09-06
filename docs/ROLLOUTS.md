# Rollout runbook — Blue/Green and Canary

Everything here is driven by **git**. `kubectl` is used to *observe*; promotion
and abort use the Argo Rollouts plugin, which mutates rollout state, not desired
state. The desired state only ever changes by commit.

Install the plugin once:

```bash
curl -fsSLo kubectl-argo-rollouts \
  https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
chmod +x kubectl-argo-rollouts && sudo mv kubectl-argo-rollouts /usr/local/bin/
```

---

## Choosing a strategy

Edit **one line** in `gitops/applications/shopfast/values.yaml` and commit:

```yaml
strategy: standard    # plain Deployment, rolling update
strategy: bluegreen   # two full stacks, instant cutover
strategy: canary      # weighted progressive shift
```

Argo CD applies the change on its next sync (or `argocd app sync shopfast`).

> The chart refuses any other value at template time, and refuses a mutable
> `latest` tag. A typo fails in CI, not in production.

---

## Blue/Green

Two complete stacks exist during a release:

- **active** service (`shopfast`) — serves production traffic
- **preview** service (`shopfast-preview`) — serves the new version only

### Release

1. Merge to `main`. CI pushes `…:<sha>` and commits the tag into `gitops/`.
2. Argo CD syncs; Rollouts brings up the new colour behind **preview**.
3. The rollout **pauses** (`autoPromotionEnabled: false`). Production is untouched.

### Verify the preview before promoting

```bash
kubectl -n shopfast get rollout shopfast -o wide
kubectl argo rollouts get rollout shopfast -n shopfast --watch

# Hit the preview stack only
kubectl -n shopfast run smoke --rm -it --restart=Never \
  --image=curlimages/curl:8.10.1 -- \
  curl -s http://shopfast-preview.shopfast.svc.cluster.local/api/hello
```

The response echoes `releaseColor` and `version` — confirm the SHA is the new one.

### Promote

```bash
kubectl argo rollouts promote shopfast -n shopfast
```

Traffic cuts over instantly. The old colour lingers for
`blueGreen.scaleDownDelaySeconds` (30s) so rollback is immediate.

### Abort

```bash
kubectl argo rollouts abort shopfast -n shopfast
```

Traffic stays on the old colour. **Then revert the tag in git** — otherwise Argo
CD re-syncs the bad version back:

```bash
git revert <ci-commit-that-bumped-the-tag>
git push
```

---

## Canary

Traffic shifts progressively: **20% → 50% → 80% → 100%**, with pauses.

### Release

1. Merge to `main` → new image → tag committed → Argo CD syncs.
2. Rollouts starts the canary at 20% and follows `canary.steps`.

### Watch it

```bash
kubectl argo rollouts get rollout shopfast -n shopfast --watch
```

In Grafana, **ShopFast → Deployments & Rollouts** shows the traffic split by
release colour and error rate by version — the panel to watch during a shift.

### Control it

```bash
kubectl argo rollouts promote shopfast -n shopfast        # skip current pause
kubectl argo rollouts promote shopfast -n shopfast --full # jump to 100%
kubectl argo rollouts abort   shopfast -n shopfast        # back to stable
```

### Automated analysis (opt-in)

Set in `gitops/applications/shopfast/values.yaml`:

```yaml
canary:
  analysis: true
```

The `AnalysisTemplate` queries VictoriaMetrics for HTTP success rate; below
`0.95` over the sample window, the rollout **aborts itself** and traffic returns
to stable. Leave this off for the first releases — it needs metric history.

---

## Rollback

**Fastest (cluster-level, buys time):**

```bash
kubectl argo rollouts undo shopfast -n shopfast
```

**Correct (git is the source of truth) — always follow up with this:**

```bash
git revert <commit>
git push
```

If you only do the first, Argo CD's `selfHeal` will restore the bad version on
its next sync. The cluster is not the source of truth; the repo is.

---

## Troubleshooting

| Symptom | Check |
|---|---|
| Rollout stuck `Progressing` | `kubectl -n shopfast describe rollout shopfast` — usually failing readiness probes |
| Pods `ImagePullBackOff` | Tag mismatch: compare `values.yaml` against `aws ecr list-images` |
| App `OutOfSync` forever | `argocd app diff shopfast` — often a mutating webhook or a field Argo does not own |
| No metrics in Grafana | `kubectl -n shopfast get vmservicescrape` and confirm `/actuator/prometheus` responds |
| Both Rollout and Deployment exist | Strategy changed without prune; `kubectl -n shopfast delete deploy shopfast` then re-sync. `verify.sh` fails the build on this. |

## Deliberate constraint

`standard` → `bluegreen`/`canary` swaps the owning object kind. Argo CD prunes
the old object, which briefly terminates all pods. Switch strategies during a
maintenance window, not during an incident.
