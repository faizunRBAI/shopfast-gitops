#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Force Argo CD to observe a fresh commit, then WAIT for the Application to
# report Synced AND Healthy.
#
# WHY THIS EXISTS
#   Argo CD polls git on an interval (~3 min by default). A job that pushes a
#   commit and exits is reporting "I wrote a file", not "the rollback took
#   effect" — and during a rollback that difference is the whole point. This
#   turns the push into a real pass/fail signal.
#
# HOW THE REFRESH IS TRIGGERED
#   The `argocd.argoproj.io/refresh: hard` ANNOTATION. Argo's application
#   controller watches for it, re-fetches the repo immediately, and REMOVES the
#   annotation itself when done.
#
#   This is safe with selfHeal enabled and is NOT a second-writer violation: the
#   annotation is a transient control signal that Argo consumes and deletes, not
#   a spec field the root App-of-Apps reconciles from git. Patching
#   `spec.source.helm.parameters` here WOULD be a second-writer bug — root would
#   revert it and fight forever. This script deliberately never touches spec.
#
# EXPECTED REVISION
#   When EXPECTED_TAG is provided, waiting for Synced+Healthy is not enough:
#   the Application could be Synced+Healthy on the OLD revision if the refresh
#   has not landed yet. So we additionally require the reported running image to
#   carry the expected tag before declaring success.
#
# Required env: APP_NAME
# Optional env: ARGOCD_NAMESPACE, EXPECTED_TAG, TIMEOUT_SECONDS, POLL_SECONDS
# ---------------------------------------------------------------------------
set -euo pipefail

APP_NAME="${APP_NAME:?APP_NAME must be set}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
EXPECTED_TAG="${EXPECTED_TAG:-}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-600}"
POLL_SECONDS="${POLL_SECONDS:-10}"

echo "=== Forcing an immediate Argo CD refresh ==="

# Argo removes this annotation once it has acted on it, so a repeat run simply
# re-adds it. Idempotent by design.
kubectl -n "${ARGOCD_NAMESPACE}" annotate application "${APP_NAME}" \
  argocd.argoproj.io/refresh=hard --overwrite

echo "Refresh requested. Waiting for Synced + Healthy" \
     "(timeout ${TIMEOUT_SECONDS}s, polling every ${POLL_SECONDS}s)."
[ -n "${EXPECTED_TAG}" ] && echo "Also requiring the running image to be tagged: ${EXPECTED_TAG}"

deadline=$(( SECONDS + TIMEOUT_SECONDS ))
last_line=""

while [ "${SECONDS}" -lt "${deadline}" ]; do
  sync_status="$(kubectl -n "${ARGOCD_NAMESPACE}" get application "${APP_NAME}" \
                  -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  health_status="$(kubectl -n "${ARGOCD_NAMESPACE}" get application "${APP_NAME}" \
                  -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  op_phase="$(kubectl -n "${ARGOCD_NAMESPACE}" get application "${APP_NAME}" \
                  -o jsonpath='{.status.operationState.phase}' 2>/dev/null || true)"
  images="$(kubectl -n "${ARGOCD_NAMESPACE}" get application "${APP_NAME}" \
                  -o jsonpath='{.status.summary.images}' 2>/dev/null || true)"

  line="sync=${sync_status:-?} health=${health_status:-?} op=${op_phase:-?} images=${images:-?}"
  if [ "${line}" != "${last_line}" ]; then
    echo "[$(date -u +%H:%M:%S)] ${line}"
    last_line="${line}"
  fi

  tag_ok=true
  if [ -n "${EXPECTED_TAG}" ]; then
    case "${images}" in
      *":${EXPECTED_TAG}\""*|*":${EXPECTED_TAG}]"*|*":${EXPECTED_TAG}"*) tag_ok=true ;;
      *) tag_ok=false ;;
    esac
  fi

  if [ "${sync_status}" = "Synced" ] && [ "${health_status}" = "Healthy" ] \
     && [ "${tag_ok}" = true ]; then
    echo
    echo "Application '${APP_NAME}' is Synced and Healthy."
    [ -n "${EXPECTED_TAG}" ] && echo "Running image carries the expected tag: ${EXPECTED_TAG}"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      {
        echo "### Argo CD reconciliation"
        echo
        echo "\`${APP_NAME}\` reached **Synced + Healthy**."
        echo
        echo "Running images: \`${images}\`"
      } >> "${GITHUB_STEP_SUMMARY}"
    fi
    exit 0
  fi

  # A failed sync operation will not fix itself by waiting.
  if [ "${op_phase}" = "Failed" ] || [ "${op_phase}" = "Error" ]; then
    message="$(kubectl -n "${ARGOCD_NAMESPACE}" get application "${APP_NAME}" \
                -o jsonpath='{.status.operationState.message}' 2>/dev/null || true)"
    echo "::error title=Argo CD sync failed::${message:-operation phase ${op_phase}}"
    exit 1
  fi

  sleep "${POLL_SECONDS}"
done

echo "::error title=Timed out::Application '${APP_NAME}' did not reach" \
     "Synced + Healthy within ${TIMEOUT_SECONDS}s. Last observed: ${last_line}"

kubectl -n "${ARGOCD_NAMESPACE}" get application "${APP_NAME}" \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,OPPHASE:.status.operationState.phase \
  || true

exit 1
