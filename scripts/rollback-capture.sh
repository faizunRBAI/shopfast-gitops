#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Capture the CURRENTLY RUNNING image tag — the rollback point.
#
# WHY ARGO CD AND NOT GIT
#   git holds the DESIRED state. During a failed or paused rollout the desired
#   state is exactly the version you are trying to escape, so capturing from
#   git would record the broken tag as the "rollback point" — precisely wrong.
#
#   Argo CD's status.summary.images reports what is ACTUALLY RUNNING, aggregated
#   from the live workload. Verified on this cluster:
#
#     $ kubectl -n argocd get application shopfast \
#         -o jsonpath={.status.summary.images}
#     ["…/shopfast-gitops-shopfast:fe97024"]
#
#   That is the field the brief names, and it is the same field the label-sync
#   CronJob will later read to keep the console tile honest.
#
# WHY NOT THE ROLLOUT/DEPLOYMENT DIRECTLY
#   Reading the Rollout's pod template would also work today, but it hard-codes
#   the workload KIND. This chart renders a Deployment under strategy=standard
#   and a Rollout under bluegreen/canary. status.summary.images is kind-agnostic,
#   so one implementation covers all three strategies.
#
# Output: writes `current_tag` and `current_image` to $GITHUB_OUTPUT when that
#         is set, and always prints them.
#
# Required env: APP_NAME, ARGOCD_NAMESPACE
# ---------------------------------------------------------------------------
set -euo pipefail

APP_NAME="${APP_NAME:?APP_NAME must be set}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"

echo "=== Capturing the current rollback point ==="

images="$(kubectl -n "${ARGOCD_NAMESPACE}" get application "${APP_NAME}" \
            -o jsonpath='{.status.summary.images}' 2>/dev/null || true)"

if [ -z "${images}" ] || [ "${images}" = "[]" ]; then
  echo "::error title=No running image::Argo CD reports no images for" \
       "Application '${APP_NAME}'. There is nothing running to roll back FROM," \
       "which means there is no safe rollback point to record."
  exit 1
fi

# status.summary.images is a JSON array. This Application deploys exactly one
# container image; take the first entry and strip the JSON punctuation without
# requiring jq on the runner.
current_image="$(printf '%s' "${images}" \
                 | tr -d '[]"' \
                 | tr ',' '\n' \
                 | head -n1 \
                 | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"

if [ -z "${current_image}" ]; then
  echo "::error title=Unparseable image::Could not read an image reference from: ${images}"
  exit 1
fi

# Split on the LAST colon so a registry host carrying a port is not mistaken
# for the tag separator.
current_tag="${current_image##*:}"
current_repo="${current_image%:*}"

if [ -z "${current_tag}" ] || [ "${current_tag}" = "${current_image}" ]; then
  echo "::error title=No tag::Running image '${current_image}' has no tag." \
       "A digest-only or untagged reference cannot be used as a rollback point."
  exit 1
fi

echo "Running image : ${current_image}"
echo "Repository    : ${current_repo}"
echo "ROLLBACK POINT: ${current_tag}"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "current_image=${current_image}"
    echo "current_repo=${current_repo}"
    echo "current_tag=${current_tag}"
  } >> "${GITHUB_OUTPUT}"
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Rollback point captured"
    echo
    echo "| field | value |"
    echo "| --- | --- |"
    echo "| currently running | \`${current_tag}\` |"
    echo "| repository | \`${current_repo}\` |"
  } >> "${GITHUB_STEP_SUMMARY}"
fi
