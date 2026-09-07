#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GATED ROLLBACK — restore the previously running image tag.
#
# "Gated" means a human decides. This script only ever runs from the
# dispatch-only `rollback` workflow, which someone triggers deliberately. It is
# never a consequence of a green pipeline, and it is not a stage of the deploy.
#
# WHAT IT DOES, IN ORDER
#   1. capture   — record the tag that is ACTUALLY RUNNING (from Argo CD)
#   2. resolve   — decide the target tag (explicit pin, else previous deploy)
#   3. abort     — stop any in-flight rollout so traffic returns to stable NOW
#   4. rewrite   — write the target tag into the values file git owns
#   5. push      — commit it (this is the durable, authoritative rollback)
#   6. sync+wait — hard-refresh Argo and block until Synced + Healthy
#
# WHAT IT DELIBERATELY DOES NOT DO
#   - It does NOT write to the Argo CD Application object. That Application is
#     reconciled FROM GIT by the root App-of-Apps and has selfHeal enabled, so
#     any live write to its spec is a second writer: root reverts it, the
#     writer re-applies it, and the app never leaves OutOfSync. This repository
#     has been burned by that exact mechanism twice. Git is the single writer,
#     for rollback as much as for deploy.
#   - It does NOT roll back infrastructure, the ACM certificate, or the chart
#     itself — only the application image tag.
#
# THE IMAGE REPOSITORY IS NOT AN INPUT
#   It is read back from what is actually running (step 1), so a rollback can
#   never silently retarget a different ECR repository than the one in service.
#   That is why REGISTRY/REPO_NAME — which the DEPLOY path needs — are
#   deliberately absent here.
#
# BLUE/GREEN INTERACTION (the surprising part — see docs/ROLLBACK.md)
#   With autoPromotionEnabled:false, rewriting the tag starts a NEW rollout that
#   PAUSES at preview. The abort in step 3 restores stable traffic immediately,
#   but the rolled-back version still needs a manual promote to become active.
#
# Required env: APP_NAME, APP_NAMESPACE, VALUES_FILE, GITHUB_REPOSITORY, BRANCH
# Optional env: TARGET_TAG, ECR_REPOSITORY, AWS_REGION, ARGOCD_NAMESPACE,
#               GITHUB_TOKEN / GITOPS_PUSH_TOKEN
# ---------------------------------------------------------------------------
set -euo pipefail

APP_NAME="${APP_NAME:?APP_NAME must be set}"
APP_NAMESPACE="${APP_NAMESPACE:?APP_NAMESPACE must be set}"
VALUES_FILE="${VALUES_FILE:?VALUES_FILE must be set}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
BRANCH="${BRANCH:?BRANCH must be set}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/gitops-push.sh
. "${SCRIPT_DIR}/gitops-push.sh"

echo "############################################################"
echo "# GATED ROLLBACK — ${APP_NAME}"
echo "############################################################"

# --- 1. capture the rollback point ------------------------------------------
capture_out="$(mktemp)"
GITHUB_OUTPUT="${capture_out}" \
APP_NAME="${APP_NAME}" \
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE}" \
  bash "${SCRIPT_DIR}/rollback-capture.sh"

CURRENT_TAG="$(grep '^current_tag=' "${capture_out}" | cut -d= -f2-)"
CURRENT_REPO="$(grep '^current_repo=' "${capture_out}" | cut -d= -f2-)"
rm -f "${capture_out}"

: "${CURRENT_TAG:?failed to capture the currently running tag}"
: "${CURRENT_REPO:?failed to capture the running image repository}"

# --- 2. resolve the target ---------------------------------------------------
echo
resolve_out="$(mktemp)"
GITHUB_OUTPUT="${resolve_out}" \
VALUES_FILE="${VALUES_FILE}" \
CURRENT_TAG="${CURRENT_TAG}" \
TARGET_TAG="${TARGET_TAG:-}" \
ECR_REPOSITORY="${ECR_REPOSITORY:-}" \
AWS_REGION="${AWS_REGION:-us-east-1}" \
  bash "${SCRIPT_DIR}/rollback-resolve.sh"

ROLLBACK_TAG="$(grep '^target_tag=' "${resolve_out}" | cut -d= -f2-)"
rm -f "${resolve_out}"

: "${ROLLBACK_TAG:?failed to resolve a rollback target}"

echo
echo "############################################################"
echo "# ROLLING BACK: ${CURRENT_TAG}  ->  ${ROLLBACK_TAG}"
echo "############################################################"

# --- 3. stop the bleeding ----------------------------------------------------
echo
APP_NAMESPACE="${APP_NAMESPACE}" \
ROLLOUT_NAME="${APP_NAME}" \
  bash "${SCRIPT_DIR}/rollback-abort-rollout.sh"

# --- 4/5. rewrite the desired state and commit it ----------------------------
echo
echo "=== Rewriting the desired state ==="

python3 "${SCRIPT_DIR}/set-image.py" \
  --values "${VALUES_FILE}" \
  --repository "${CURRENT_REPO}" \
  --tag "${ROLLBACK_TAG}"

git add "${VALUES_FILE}"

if ! gitops_push "ci: rollback ${APP_NAME} ${CURRENT_TAG} -> ${ROLLBACK_TAG}"; then
  echo "::error title=Rollback push failed::The desired state was NOT committed," \
       "so the cluster still runs ${CURRENT_TAG}. Fix the push credential and re-run."
  exit 1
fi

# --- 6. prove it actually took effect ---------------------------------------
echo
APP_NAME="${APP_NAME}" \
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE}" \
EXPECTED_TAG="${ROLLBACK_TAG}" \
  bash "${SCRIPT_DIR}/argocd-sync-wait.sh"

echo
echo "############################################################"
echo "# ROLLBACK COMPLETE — ${APP_NAME} restored to ${ROLLBACK_TAG}"
echo "############################################################"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## Rollback complete"
    echo
    echo "\`${CURRENT_TAG}\` → **\`${ROLLBACK_TAG}\`**"
    echo
    echo "> Under blue/green with \`autoPromotionEnabled: false\`, the restored"
    echo "> version comes up behind the PREVIEW service and waits for a manual"
    echo "> promote. Traffic is on the stable version in the meantime."
    echo ">"
    echo "> Promote it with the argo rollouts plugin — see docs/ROLLBACK.md."
  } >> "${GITHUB_STEP_SUMMARY}"
fi
