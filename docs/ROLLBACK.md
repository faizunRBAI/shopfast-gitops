# Gated rollback

Restores the previously running ShopFast image. It is **gated**: it only runs
because a human dispatched it. Nothing about a green — or red — pipeline
triggers a rollback automatically.

## How to run it

**Actions → `rollback` → Run workflow.**

That is the whole procedure for the common case. Leave everything alone and it
restores the version that was running before the current one.

### Rolling back further than one version

Set the repository variable `ROLLBACK_TARGET_TAG` to an immutable Git SHA tag
(Settings → Secrets and variables → Actions → Variables), dispatch the workflow,
then **clear the variable again**.

Clearing it matters. A stale pin left in place means the next person to hit
"Run workflow" during an incident silently rolls back to a tag someone chose
weeks ago instead of the previous version.

> A repository variable rather than a normal `workflow_dispatch` input because
> this workflow is *rendered* from `.udap/pipeline.yaml`, whose schema cannot
> declare dispatch inputs. Hand-editing `.github/workflows/rollback.yml` would
> be overwritten on the next render.

## What it does

```
1. capture    read the ACTUALLY RUNNING tag from the Argo CD Application
2. resolve    pick the target: explicit pin, else the previous deployed tag
3. abort      stop any in-flight rollout -> traffic returns to stable NOW
4. rewrite    write the target tag into gitops/applications/shopfast/values.yaml
5. push       commit it  <- the durable, authoritative rollback
6. sync+wait  hard-refresh Argo CD, block until Synced + Healthy
```

Steps 3 and 5 are deliberately separated. The abort is *fast* — it stops user
impact within seconds by routing traffic back to the stable ReplicaSet. The
commit is *durable* — it changes what the cluster will converge to. You want
both, in that order.

### It captures from Argo CD, not from git

git holds the **desired** state. During a failed or paused rollout the desired
state is exactly the version you are trying to escape, so capturing from git
would record the broken tag as the rollback point.

`status.summary.images` on the Application reports what is **actually running**.
That is the rollback point.

### It writes to git, never to the Application

The rollback never runs `argocd app set` or `kubectl patch application`.

The `shopfast` Application has `selfHeal: true` and is reconciled from git by
the root App-of-Apps. Patching it live creates a second writer: root reverts the
patch, the patcher re-applies it, and the Application never leaves `OutOfSync`.
This repository has hit that failure twice already. Git is the single writer —
for rollback exactly as much as for deploy.

`scripts/verify-rollback.sh` asserts this in CI, so the property cannot quietly
regress.

## Refusals

The rollback fails loudly rather than proceeding when the target is:

| Target | Why it is refused |
| --- | --- |
| `latest` | Mutable. A rollback that can change under you is not a rollback. |
| `bootstrap` / `PLACEHOLDER*` | The un-rendered bootstrap seed; no such image exists. |
| the currently running tag | A no-op that would still churn a rollout for nothing. |
| a tag absent from ECR | Would replace a degraded service with `ImagePullBackOff`. |
| no previous version in history | Refuses rather than inventing a target. |

Every one of these is asserted offline by `scripts/verify-rollback.sh`, which
runs in the `security` stage of the deploy pipeline.

## The surprising part: blue/green

**A rollback under blue/green does not immediately put the old version back into
production.**

With `blueGreen.autoPromotionEnabled: false` (the current setting), rewriting the
image tag starts a **new rollout**, and that rollout pauses at the *preview*
service exactly like any other deploy. The restored version is validated before
it takes traffic — which is the point of the manual gate, but it is not what
most people expect the word "rollback" to mean.

What actually protects you during those minutes is **step 3**: the abort put
traffic back on the stable version immediately.

To finish the rollback and make the restored version active:

```bash
kubectl argo rollouts promote shopfast -n shopfast
```

Watch it first if you want:

```bash
kubectl argo rollouts get rollout shopfast -n shopfast --watch
```

Under `strategy: standard` (a plain Deployment) there is no preview and no
promotion — the git rewrite alone completes the rollback.

## What it does NOT roll back

- **Infrastructure.** Terraform is not touched. Revert the commit and re-run
  the deploy pipeline.
- **The ACM certificate / ingress.** Managed separately; a rollback leaves the
  current certificate ARN in place.
- **Data.** No migration is reversed. If a release included a destructive schema
  change, rolling the image back does not undo it.
- **Other Applications.** Only `shopfast` has a deployable image today.

## Verifying it worked

Do not trust the health badge — the `monitoring` Application reported `Healthy`
for an hour while every one of its syncs failed. Check:

```bash
# 1. the Application reports the target tag
kubectl -n argocd get application shopfast -o jsonpath='{.status.summary.images}'

# 2. the sync operation actually succeeded
kubectl -n argocd get application shopfast \
  -o custom-columns=SYNC:.status.sync.status,HEALTH:.status.health.status,OP:.status.operationState.phase

# 3. the rollout is serving the restored version
kubectl argo rollouts get rollout shopfast -n shopfast
```

The workflow itself performs check 1 and 2 and fails if they do not hold, so a
green rollback run already means more than "the file was written".
