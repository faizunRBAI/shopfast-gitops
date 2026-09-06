#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GitOps image-tag commit.
#
# This is THE deployment trigger. CI never touches the cluster: it rewrites the
# image reference in the deployed values file and pushes that commit. Argo CD
# observes the change and reconciles. If this push does not land, the new image
# exists in ECR but nothing deploys it.
#
# AUTHENTICATION: the default GITHUB_TOKEN is scoped `Contents: read` for this
# repository, so `git push` fails with 403 ("Permission to ... denied to
# github-actions[bot]"). The platform pipeline spec has no `permissions:` key to
# widen it, so the push is authenticated with GITOPS_PUSH_TOKEN, a repo-scoped
# token stored as a repository secret.
#
# NOTE ON THE HEADER: actions/checkout installs its OWN
# http.https://github.com/.extraheader carrying the read-only GITHUB_TOKEN. A
# second value would simply be appended (git treats it as multi-valued), and the
# stale read-only header can win. This script therefore UNSETS the existing
# header before setting its own, and restores nothing afterwards beyond removing
# its credential.
#
# The token is passed via a header rather than embedded in the remote URL, since
# a URL-embedded credential is persisted into .git/config and echoed back in the
# "remote:" lines of git error output.
#
# Required env: REGISTRY, TAG, REPO_NAME, GITHUB_REPOSITORY, BRANCH,
#               GITOPS_PUSH_TOKEN
# ---------------------------------------------------------------------------
set -euo pipefail

: "${REGISTRY:?REGISTRY must be set}"
: "${TAG:?TAG must be set}"
: "${REPO_NAME:?REPO_NAME must be set}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
: "${BRANCH:?BRANCH must be set}"

VALUES="gitops/applications/shopfast/values.yaml"

python3 scripts/set-image.py \
  --values "${VALUES}" \
  --repository "${REGISTRY}/${REPO_NAME}-shopfast" \
  --tag "${TAG}"

git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
git add "${VALUES}"

if git diff --cached --quiet; then
  echo "GitOps values already at this revision — nothing to commit."
  echo "Argo CD is already tracking the desired image; no push needed."
  exit 0
fi

git commit -m "ci: deploy shopfast ${TAG}"

if [ -z "${GITOPS_PUSH_TOKEN:-}" ]; then
  echo "::error title=GitOps push blocked::GITOPS_PUSH_TOKEN is not set. The" \
       "default GITHUB_TOKEN only has Contents: read, so the image-tag commit" \
       "cannot be pushed and Argo CD will never see the new image."
  exit 1
fi

HEADER_KEY='http.https://github.com/.extraheader'

cleanup() {
  git config --local --unset-all "${HEADER_KEY}" 2>/dev/null || true
}
trap cleanup EXIT

# Drop the checkout action's read-only header before installing ours.
git config --local --unset-all "${HEADER_KEY}" 2>/dev/null || true

AUTH_VALUE="$(printf 'x-access-token:%s' "${GITOPS_PUSH_TOKEN}" | base64 -w0)"
git config --local "${HEADER_KEY}" "Authorization: Basic ${AUTH_VALUE}"
unset AUTH_VALUE

echo "Pushing the GitOps update to ${BRANCH}…"
git push "https://github.com/${GITHUB_REPOSITORY}.git" "HEAD:${BRANCH}"

echo "GitOps update pushed. Argo CD will reconcile shopfast to ${TAG}."
