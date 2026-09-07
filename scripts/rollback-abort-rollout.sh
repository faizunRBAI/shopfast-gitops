#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Abort an in-flight Argo Rollout so traffic returns to the STABLE version
# immediately, before the git rewrite is committed.
#
# WHY THIS RUNS FIRST
#   Rewriting the image tag in git is DURABLE but SLOW: Argo must notice the
#   commit, sync it, and the Rollouts controller must then bring up the old
#   version and shift traffic. If a bad canary is mid-shift, that is minutes of
#   continued user impact.
#
#   `kubectl argo rollouts abort` is IMMEDIATE: it stops the progression and
#   routes all traffic back to the stable ReplicaSet, which is by definition the
#   last version that was actually promoted. So: abort for the bleeding, commit
#   for the cure.
#
# WHY THIS IS NOT A "SECOND WRITER" VIOLATION
#   Aborting mutates ROLLOUT STATUS (.status.abort / pause conditions), not the
#   Application's desired SPEC. Argo CD's selfHeal reconciles spec fields from
#   git; it does not fight the Rollouts controller over its own status. The
#   thing that WOULD be a second-writer bug is `argocd app set` / `kubectl patch`
#   on the Application spec — this repo has been burned by that twice, and the
#   rollback path deliberately does neither.
#
# THE BRIEF'S REQUIREMENT
#   "an aborted/failed rollout must not be promoted to the production version"
#   An aborted Rollout is DEGRADED and will not self-promote. Combined with
#   autoPromotionEnabled:false, the new version cannot reach production traffic
#   without a deliberate human promote.
#
# No-op (exit 0) when there is no Rollout, or it is not in flight.
#
# Required env: APP_NAMESPACE, ROLLOUT_NAME
# ---------------------------------------------------------------------------
set -euo pipefail

APP_NAMESPACE="${APP_NAMESPACE:?APP_NAMESPACE must be set}"
ROLLOUT_NAME="${ROLLOUT_NAME:?ROLLOUT_NAME must be set}"

echo "=== Checking for an in-flight rollout ==="

if ! kubectl -n "${APP_NAMESPACE}" get rollout "${ROLLOUT_NAME}" >/dev/null 2>&1; then
  echo "No Rollout '${ROLLOUT_NAME}' in namespace '${APP_NAMESPACE}'."
  echo "Nothing to abort — this environment is running a plain Deployment" \
       "(strategy=standard), where the git rewrite alone is the rollback."
  exit 0
fi

phase="$(kubectl -n "${APP_NAMESPACE}" get rollout "${ROLLOUT_NAME}" \
          -o jsonpath='{.status.phase}' 2>/dev/null || true)"
echo "Rollout phase: ${phase:-<unknown>}"

case "${phase}" in
  Paused|Progressing|Degraded)
    echo "Rollout is in flight — aborting so traffic returns to the stable version."
    if kubectl argo rollouts abort "${ROLLOUT_NAME}" -n "${APP_NAMESPACE}"; then
      echo "Abort issued. Traffic is on the stable ReplicaSet."
    else
      # A failed abort must NOT stop the rollback: the git rewrite is the
      # durable fix and is strictly more important than the fast one.
      echo "::warning title=Abort failed::Could not abort the rollout." \
           "Continuing with the git rewrite, which is the authoritative rollback."
    fi

    kubectl -n "${APP_NAMESPACE}" get rollout "${ROLLOUT_NAME}" \
      -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,STABLE:.status.stableRS,CURRENT:.status.currentPodHash \
      || true
    ;;
  Healthy)
    echo "Rollout is Healthy and not mid-progression — nothing to abort."
    echo "The git rewrite below will start a NEW rollout back to the target tag."
    ;;
  *)
    echo "Rollout phase '${phase:-<unknown>}' needs no abort."
    ;;
esac

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Rollout abort check"
    echo
    echo "Phase before rollback: \`${phase:-unknown}\`"
  } >> "${GITHUB_STEP_SUMMARY}"
fi
