#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GitOps desired-state commit.
#
# This is THE deployment trigger. CI never touches the cluster: it rewrites the
# deployed values file and pushes that commit. Argo CD observes the change and
# reconciles. If this push does not land, the new image exists in ECR but
# nothing deploys it.
#
# WHAT THIS WRITES
#   image.repository / image.tag  — the immutable Git SHA image reference
#   ingress.certificateArn        — the ACM cert ARN, when CERT_ARN is provided
#
#   The certificate ARN belongs HERE, in git, and not as a Helm parameter
#   patched onto the shopfast Application at bootstrap time. The root
#   App-of-Apps reconciles that Application from git; an apply-time patch is a
#   second writer for the same field, so root reverts it, bootstrap re-adds it,
#   and the Application stays OutOfSync forever with its workload never
#   created. One writer, one source of truth.
#
# AUTHENTICATION
#   The repository's default workflow permission is "read and write"
#   (Settings -> Actions -> General -> Workflow permissions), so the built-in
#   workflow credential can push. That is the primary path — no extra secret.
#
#   GITOPS_PUSH_TOKEN is honoured as an override when present, for the case
#   where the repository is later restricted to read-only workflows or moved
#   under an org whose policy forbids write credentials.
#
#   Credentials are supplied through GIT_ASKPASS: git EXECUTES the helper and
#   reads the value from its stdout. Do NOT switch this to
#   `git config http.<url>.extraheader` — git parses config keys as
#   section.subsection.variable, and the unquoted dots inside an https:// URL
#   make it store the value under a key git never consults at push time, which
#   silently produces "could not read Username for 'https://github.com'".
#
#   Nothing sensitive reaches a command line, a URL, or .git/config.
#
# Required env: REGISTRY, TAG, REPO_NAME, GITHUB_REPOSITORY, BRANCH
# Optional env: CERT_ARN, GITOPS_PUSH_TOKEN
# ---------------------------------------------------------------------------
set -euo pipefail

: "${REGISTRY:?REGISTRY must be set}"
: "${TAG:?TAG must be set}"
: "${REPO_NAME:?REPO_NAME must be set}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
: "${BRANCH:?BRANCH must be set}"

VALUES="gitops/applications/shopfast/values.yaml"

SET_IMAGE_ARGS=(
  --values "${VALUES}"
  --repository "${REGISTRY}/${REPO_NAME}-shopfast"
  --tag "${TAG}"
)

# The ARN is only written once ACM has actually issued the certificate. Writing
# an ARN for a PENDING_VALIDATION certificate is harmless (the controller simply
# cannot attach it yet), so it is included whenever terraform reports one.
if [ -n "${CERT_ARN:-}" ]; then
  SET_IMAGE_ARGS+=(--certificate-arn "${CERT_ARN}")
  echo "Certificate ARN resolved from terraform state — writing it into ${VALUES}."
else
  echo "::warning title=No certificate ARN::CERT_ARN was empty; leaving" \
       "ingress.certificateArn unchanged. The ShopFast ingress will have no" \
       "HTTPS listener until an ARN is committed."
fi

python3 scripts/set-image.py "${SET_IMAGE_ARGS[@]}"

git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
git add "${VALUES}"

if git diff --cached --quiet; then
  echo "GitOps values already at this revision — nothing to commit."
  echo "Argo CD is already tracking the desired state; no push needed."
  exit 0
fi

git commit -m "ci: deploy shopfast ${TAG}"

# Select the push credential: an explicit override wins, otherwise the
# workflow's built-in credential. Both arrive as environment variables from the
# pipeline spec; neither value is ever written here.
if [ -n "${GITOPS_PUSH_TOKEN:-}" ]; then
  export GIT_PUSH_CREDENTIAL="${GITOPS_PUSH_TOKEN}"
  echo "Using the GITOPS_PUSH_TOKEN override for the push."
elif [ -n "${GITHUB_TOKEN:-}" ]; then
  export GIT_PUSH_CREDENTIAL="${GITHUB_TOKEN}"
  echo "Using the workflow credential for the push."
else
  echo "::error title=GitOps push blocked::No push credential available." \
       "Set repository Settings -> Actions -> General -> Workflow permissions" \
       "to 'Read and write permissions'. Without this the image-tag commit" \
       "cannot be pushed and Argo CD will never see the new image."
  exit 1
fi

# Credential helper: git asks for "Username" then "Password"; the prompt text
# arrives as $1, so answer according to which is being requested.
ASKPASS="$(mktemp)"
cleanup() { rm -f "${ASKPASS}"; }
trap cleanup EXIT
chmod 700 "${ASKPASS}"

cat > "${ASKPASS}" <<'ASKPASS_EOF'
#!/usr/bin/env bash
case "$1" in
  *[Uu]sername*) printf '%s\n' "x-access-token" ;;
  *)             printf '%s\n' "${GIT_PUSH_CREDENTIAL}" ;;
esac
ASKPASS_EOF

chmod 700 "${ASKPASS}"

echo "Pushing the GitOps update to ${BRANCH}…"

# GIT_TERMINAL_PROMPT=0 turns a credential failure into an immediate error
# rather than a hang waiting on a tty that does not exist.
GIT_ASKPASS="${ASKPASS}" \
GIT_TERMINAL_PROMPT=0 \
  git push "https://github.com/${GITHUB_REPOSITORY}.git" "HEAD:${BRANCH}"

echo "GitOps update pushed. Argo CD will reconcile shopfast to ${TAG}."
