#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Resolve WHICH tag a gated rollback should restore.
#
# TARGET SELECTION
#   1. An explicit TARGET_TAG input always wins — "roll back three versions" or
#      "roll back to the tag I know was good" must be expressible.
#   2. Otherwise: walk the git history of the deployed values file and take the
#      most recent PREVIOUS image tag that differs from the running one.
#
# WHY GIT HISTORY RATHER THAN A STATE FILE
#   The values file's history IS the deploy history — scripts/gitops-commit.sh
#   writes exactly one commit per deploy. Introducing a separate "previous tag"
#   state file would add a second writer that can drift out of step with the
#   thing it claims to describe, and a rollback pointer that is silently wrong
#   is worse than no pointer at all.
#
# REFUSALS (each one is an outage this prevents)
#   - 'latest' or empty            : the brief forbids it; a mutable tag defeats
#                                    the entire point of a rollback point.
#   - the currently running tag    : a no-op that would still churn a rollout.
#   - a tag absent from ECR        : rolling back to an unpullable image turns a
#                                    degraded service into ImagePullBackOff.
#
# Output: writes `target_tag` to $GITHUB_OUTPUT when set; always prints it.
#
# Required env: VALUES_FILE, CURRENT_TAG
# Optional env: TARGET_TAG, ECR_REPOSITORY, AWS_REGION, HISTORY_DEPTH
# ---------------------------------------------------------------------------
set -euo pipefail

VALUES_FILE="${VALUES_FILE:?VALUES_FILE must be set}"
CURRENT_TAG="${CURRENT_TAG:?CURRENT_TAG must be set}"
TARGET_TAG="${TARGET_TAG:-}"
HISTORY_DEPTH="${HISTORY_DEPTH:-50}"

echo "=== Resolving the rollback target ==="
echo "Currently running: ${CURRENT_TAG}"

# --- read the image tag as it stood in one revision of the values file -------
# Scoped to the `image:` block: `tag:` appears under more than one top-level key
# in a real values file, and an unscoped match would read the wrong one.
tag_at_revision() {
  local rev="$1"
  git show "${rev}:${VALUES_FILE}" 2>/dev/null | awk '
    /^[^[:space:]#]/ { in_image = ($0 ~ /^image:/) }
    in_image && /^[[:space:]]+tag:[[:space:]]*/ {
      line = $0
      sub(/^[[:space:]]+tag:[[:space:]]*/, "", line)
      gsub(/["'"'"']/, "", line)
      sub(/[[:space:]]*(#.*)?$/, "", line)
      if (line != "") { print line; exit }
    }
  '
}

if [ -n "${TARGET_TAG}" ]; then
  echo "Explicit target supplied: ${TARGET_TAG}"
  resolved="${TARGET_TAG}"
else
  echo "No explicit target — walking the deploy history of ${VALUES_FILE}."
  resolved=""

  # --follow is deliberately omitted: this file has never been renamed, and
  # --follow changes the revision ordering semantics in ways that would make
  # "the previous deploy" ambiguous.
  revisions="$(git log --format=%H -n "${HISTORY_DEPTH}" -- "${VALUES_FILE}" 2>/dev/null || true)"

  if [ -z "${revisions}" ]; then
    echo "::error title=No history::No commit history found for ${VALUES_FILE}." \
         "Cannot determine a previous version; supply an explicit target tag."
    exit 1
  fi

  for rev in ${revisions}; do
    candidate="$(tag_at_revision "${rev}")"
    [ -n "${candidate}" ] || continue
    if [ "${candidate}" != "${CURRENT_TAG}" ]; then
      resolved="${candidate}"
      echo "Previous deployed tag found in ${rev:0:7}: ${resolved}"
      break
    fi
  done

  if [ -z "${resolved}" ]; then
    echo "::error title=No previous version::Walked ${HISTORY_DEPTH} revisions of" \
         "${VALUES_FILE} and found no deployed tag other than the running one" \
         "(${CURRENT_TAG}). There is nothing to roll back to."
    exit 1
  fi
fi

# --- refusals ---------------------------------------------------------------
case "${resolved}" in
  ""|latest|LATEST)
    echo "::error title=Refusing a mutable tag::Rollback target '${resolved}' is" \
         "not a fixed version. A mutable tag can change under you, which is" \
         "exactly what a rollback must never depend on. Use an immutable Git SHA tag."
    exit 1
    ;;
  PLACEHOLDER*|bootstrap)
    echo "::error title=Refusing a bootstrap placeholder::Rollback target" \
         "'${resolved}' is the un-rendered bootstrap seed, not a real build." \
         "It does not exist in ECR and would fail to pull."
    exit 1
    ;;
esac

if [ "${resolved}" = "${CURRENT_TAG}" ]; then
  echo "::error title=Nothing to do::Rollback target '${resolved}' is already the" \
       "running version. Refusing to churn a rollout for no change."
  exit 1
fi

# --- prove the image exists before promising to deploy it -------------------
# Skipped only when ECR_REPOSITORY is unset, which is the offline/self-test path.
if [ -n "${ECR_REPOSITORY:-}" ]; then
  echo "Verifying ${ECR_REPOSITORY}:${resolved} exists in ECR…"
  if aws ecr describe-images \
        --repository-name "${ECR_REPOSITORY}" \
        --image-ids imageTag="${resolved}" \
        --region "${AWS_REGION:-us-east-1}" >/dev/null 2>&1; then
    echo "Image present in ECR."
  else
    echo "::error title=Rollback target not in ECR::No image tagged" \
         "'${resolved}' exists in repository '${ECR_REPOSITORY}'. Rolling back" \
         "to it would replace a degraded service with ImagePullBackOff."
    exit 1
  fi
else
  echo "ECR_REPOSITORY unset — skipping the registry existence check."
fi

echo "ROLLBACK TARGET: ${resolved}"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "target_tag=${resolved}" >> "${GITHUB_OUTPUT}"
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Rollback target resolved"
    echo
    echo "| field | value |"
    echo "| --- | --- |"
    echo "| from (running) | \`${CURRENT_TAG}\` |"
    echo "| to (target) | \`${resolved}\` |"
  } >> "${GITHUB_STEP_SUMMARY}"
fi
