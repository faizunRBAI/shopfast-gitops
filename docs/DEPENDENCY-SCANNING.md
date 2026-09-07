# Dependency vulnerability scanning

OWASP dependency-check runs in its **own workflow**, not in the deploy pipeline.

| | |
|---|---|
| Workflow | `.github/workflows/security-deps.yml` (`security-deps`) |
| Trigger | Manual — **Actions → security-deps → Run workflow** |
| Script | `scripts/dependency-scan.sh` (unchanged) |
| Threshold | `application/pom.xml` → `security.failBuildOnCVSS` (unchanged) |
| Report | `dependency-check-report` artifact — HTML + JSON, 30-day retention |
| Budget | 180 minutes |

## Why it is not in the deploy pipeline

dependency-check must download the **entire NVD corpus (~387,000 records)**
before it can inspect a single JAR. There is no incremental or partial mode.
That made every deployment gated on `nvd.nist.gov` throughput, which we do not
control and which is not stable:

| Date | Feed rate | Outcome |
|---|---|---|
| 2026-09-06 | ~97,000 rec/min | download completed in 4m46s — stage passed |
| 2026-09-07 | ~2,600 rec/min | 26% complete at the cap — stage cancelled |
| 2026-09-07 (rotated key) | ~15,000 rec/min | NVD aborted the fetch itself |

The last run failed with `RejectedExecutionException` **5m55s into a 25-minute
budget** — dependency-check exhausted its retries on a failing NVD request
(`startIndex=340000`), shut down its HTTP executor pool, then tried to schedule
an in-flight retry onto that terminated pool. That is a feed fault, not a
timeout, and not a defect in this repository.

Rotating the NVD API key was tested and **exonerated the credential**: the new
key measurably improved throughput (~6x) and the fetch still aborted.

### Why caching alone could not fix it

`actions/cache` writes its entry only when the job's steps succeed. A download
that never completes never seeds the cache, so the next run starts cold and
fails the same way — a **cold-cache deadlock**. Verified: `gh api
/repos/.../actions/caches` listed only `setup-java-*` entries, no `nvd-db-*`.

The 180-minute budget in this workflow is what breaks that deadlock: the
download can finish even on a degraded feed, and `security-deps` is the only
writer of the shared `nvd-db-*` cache.

## What did NOT change

This is a **scope** change, not a weakening of the gate:

- The scan itself is byte-for-byte the same script.
- `security.failBuildOnCVSS` is unchanged — see the accepted-risk rationale in
  `application/pom.xml`.
- No `continue-on-error`, no deleted checks, no loosened threshold.
- The report is still published as a build artifact.

What changed is that a third-party feed outage now delays a **report** instead
of blocking a **deployment**.

## What still gates every deploy

The `security` stage keeps all of its other checks, and they run before any AWS
spend:

1. Helm chart lints under all three strategies (`standard`, `bluegreen`, `canary`)
2. Blue/Green and Canary never render a `Deployment` (`verify-chart-exclusivity.sh`)
3. GitOps manifests are fully resolved — no placeholders (`verify-gitops-manifests.sh`)
4. The ACM certificate covers every declared hostname (`verify-cert-sans.sh`)

Container image scanning is also **unaffected**: Trivy still runs on the built
image in `build_push` (`scripts/scan-image.sh`), plus ECR scan-on-push.

## Operating it

Run it after any dependency change, and on a regular cadence:

```
gh workflow run security-deps.yml
gh run watch
```

Then download the report from the run's artifacts.

### Adding a schedule

The pipeline renderer emits `workflow_dispatch` only, so this workflow is
manual by design. To have it run unattended, add a `schedule:` trigger to
`.github/workflows/security-deps.yml` **in GitHub directly** — but note that
`.udap/pipeline.yaml` is the source of truth and re-rendering overwrites the
file. The durable alternative is a repository-level scheduled workflow that
dispatches this one.

### If a scan fails

Do **not** disable it, lower the threshold, or add `continue-on-error`. Check
whether NVD is degraded first — the failure signature is a download that stalls
or aborts before analysis begins. Re-run once the feed recovers; the first
successful run seeds the cache and later runs fetch only the delta.
