#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Shared GitOps push implementation.
#
# SOURCED, not executed: callers `source scripts/gitops-push.sh` and then call
# gitops_push "<commit message>". Two callers exist:
#   - scripts/gitops-commit.sh   (deploy path: forward to a new image tag)
#   - scripts/rollback.sh        (gated rollback: back to a previous tag)
#
# WHY THIS IS SHARED RATHER THAN COPIED
#   The credential handling below is the product of a 403 debugging cycle. A
#   second hand-written copy is a second thing to get subtly wrong at the exact
#   moment you need it most — during a rollback, under pressure. One
#   implementation, two callers.
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
# Required env: GITHUB_REPOSITORY, BRANCH
# Optional env: GITOPS_PUSH_TOKEN (override), GITHUB_TOKEN (default)
# ---------------------------------------------------------------------------

# gitops_push <commit-message>
#
# Commits whatever is already staged and pushes it to $BRANCH. Returns 0 and
# does nothing when the index is empty — an idempotent re-run is not an error.
gitops_push() {
  local message="${1:?gitops_push requires a commit message}"

  : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
  : "${BRANCH:?BRANCH must be set}"

  git config user.name "github-actions[bot]"
  git config user.email "github-actions[bot]@users.noreply.github.com"

  if git diff --cached --quiet; then
    echo "Nothing staged — desired state already at this revision."
    return 0
  fi

  git commit -m "${message}"

  # Select the push credential: an explicit override wins, otherwise the
  # workflow's built-in credential. Neither value is ever written here.
  if [ -n "${GITOPS_PUSH_TOKEN:-}" ]; then
    export GIT_PUSH_CREDENTIAL="${GITOPS_PUSH_TOKEN}"
    echo "Using the GITOPS_PUSH_TOKEN override for the push."
  elif [ -n "${GITHUB_TOKEN:-}" ]; then
    export GIT_PUSH_CREDENTIAL="${GITHUB_TOKEN}"
    echo "Using the workflow credential for the push."
  else
    echo "::error title=GitOps push blocked::No push credential available." \
         "Set repository Settings -> Actions -> General -> Workflow permissions" \
         "to 'Read and write permissions'. Without this the commit cannot be" \
         "pushed and Argo CD will never see the change."
    return 1
  fi

  # Credential helper: git asks for "Username" then "Password"; the prompt text
  # arrives as $1, so answer according to which is being requested.
  local askpass
  askpass="$(mktemp)"
  chmod 700 "${askpass}"

  cat > "${askpass}" <<'ASKPASS_EOF'
#!/usr/bin/env bash
case "$1" in
  *[Uu]sername*) printf '%s\n' "x-access-token" ;;
  *)             printf '%s\n' "${GIT_PUSH_CREDENTIAL}" ;;
esac
ASKPASS_EOF

  chmod 700 "${askpass}"

  echo "Pushing to ${BRANCH}…"

  # GIT_TERMINAL_PROMPT=0 turns a credential failure into an immediate error
  # rather than a hang waiting on a tty that does not exist.
  local rc=0
  GIT_ASKPASS="${askpass}" \
  GIT_TERMINAL_PROMPT=0 \
    git push "https://github.com/${GITHUB_REPOSITORY}.git" "HEAD:${BRANCH}" || rc=$?

  rm -f "${askpass}"
  return "${rc}"
}
