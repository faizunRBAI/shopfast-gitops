#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GitOps image-tag commit.
#
# This is THE deployment trigger. CI never touches the cluster: it rewrites the
# image reference in the deployed values file and pushes that commit. Argo CD
# observes the change and reconciles. If this push does not land, the new image
# exists in ECR but nothing deploys it.
#
# AUTHENTICATION — why GIT_ASKPASS and not http.extraheader:
#
#   The default GITHUB_TOKEN is scoped `Contents: read`, so an unauthenticated
#   push fails 403. The platform pipeline spec has no `permissions:` key to
#   widen it, so we supply our own repo-scoped token (GITOPS_PUSH_TOKEN).
#
#   A previous attempt injected it via
#       git config --local "http.https://github.com/.extraheader" ...
#   That FAILED with "could not read Username for 'https://github.com'". Git
#   parses config keys as section.subsection.variable, and the unquoted dots
#   inside the URL make it store the value under a different key than the one
#   git consults when pushing — so the push ran with no credential at all. (It
#   did successfully remove the checkout action's header, which is why the error
#   changed from 403 to "no credential".)
#
#   GIT_ASKPASS sidesteps config parsing entirely: git EXECUTES the named
#   program and reads the credential from its stdout. No quoting rules, no
#   subsections, nothing to mis-parse.
#
# The token is passed to the helper through the environment and never appears in
# a command line, a URL, or .git/config.
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

# Credential helper. Git calls this once for "Username" and once for "Password";
# the prompt text is passed as $1, so we answer based on which is being asked.
ASKPASS="$(mktemp)"
cleanup() { rm -f "${ASKPASS}"; }
trap cleanup EXIT
chmod 700 "${ASKPASS}"

cat > "${ASKPASS}" <<'ASKPASS_EOF'
#!/usr/bin/env bash
case "$1" in
  *[Uu]sername*) printf '%s\n' "x-access-token" ;;
  *[Pp]assword*) printf '%s\n' "${GITOPS_PUSH_TOKEN}" ;;
  *)             printf '%s\n' "${GITOPS_PUSH_TOKEN}" ;;
esac
ASKPASS_EOF

chmod 700 "${ASKPASS}"

echo "Pushing the GitOps update to ${BRANCH}…"

# GIT_TERMINAL_PROMPT=0 turns a credential failure into an immediate error
# instead of a hang. GITOPS_PUSH_TOKEN must be exported so the helper sees it.
export GITOPS_PUSH_TOKEN
GIT_ASKPASS="${ASKPASS}" \
GIT_TERMINAL_PROMPT=0 \
  git push "https://github.com/${GITHUB_REPOSITORY}.git" "HEAD:${BRANCH}"

echo "GitOps update pushed. Argo CD will reconcile shopfast to ${TAG}."
