#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GitOps manifest guard — runs in the `security` stage, BEFORE any AWS
# resource is touched.
#
# WHY THIS EXISTS
#   The root App-of-Apps reconciles gitops/apps/children/*.yaml FROM GIT. Any
#   value injected into a live Application at bootstrap time is therefore
#   reverted on root's next sync, and the Application is left with whatever git
#   actually contains. When git contained the literal string
#   PLACEHOLDER_REPO_URL, the result was:
#
#     status: "Failed to load target state: ... repository not found"
#
#   with the workload silently never created — a failure that only surfaced
#   minutes later, in Argo CD, long after CI had gone green.
#
#   These checks make that class of mistake fail in ~2 seconds instead.
# ---------------------------------------------------------------------------
set -uo pipefail

FAILURES=0
fail() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; FAILURES=$((FAILURES + 1)) || true; }
pass() { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }

APPS_DIR="gitops/apps"
ROOT_APP="${APPS_DIR}/root-app.yaml"
CHILDREN_DIR="${APPS_DIR}/children"

echo "=== GitOps manifest verification ==="

# 1. No unresolved placeholders anywhere under gitops/.
if grep -rn 'PLACEHOLDER_REPO_URL' gitops/ >/dev/null 2>&1; then
  grep -rn 'PLACEHOLDER_REPO_URL' gitops/ || true
  fail "unresolved PLACEHOLDER_REPO_URL in gitops/ — the root app reconciles these from git, so the placeholder would reach the cluster verbatim"
else
  pass "no unresolved repo-URL placeholders"
fi

# 2. Every Application's repoURL must be a real URL.
for f in "${ROOT_APP}" "${CHILDREN_DIR}"/*.yaml; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"

  url="$(grep -E '^\s+repoURL:' "$f" | head -n1 | sed -E 's/^\s+repoURL:\s*//')"
  if [ -z "${url}" ]; then
    fail "${name}: no repoURL found"
    continue
  fi

  case "${url}" in
    https://*|oci://*|git@*)
      pass "${name}: repoURL is a real URL (${url})"
      ;;
    *)
      fail "${name}: repoURL is not a resolvable URL: '${url}'"
      ;;
  esac
done

# 3. Child Applications must not carry apply-time helm parameters. Anything the
#    chart needs belongs in a values file git owns, or root will fight whoever
#    injects it.
for f in "${CHILDREN_DIR}"/*.yaml; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  if grep -qE '^\s+parameters:' "$f"; then
    fail "${name}: declares helm parameters; put environment-specific values in a committed values file instead"
  else
    pass "${name}: no apply-time helm parameters"
  fi
done

# 4. The bootstrap script must not rewrite the App-of-Apps manifests.
BOOTSTRAP="gitops/bootstrap/bootstrap.sh"
if [ -f "${BOOTSTRAP}" ]; then
  if grep -E '^[^#]*sed' "${BOOTSTRAP}" | grep -q 'gitops/apps'; then
    fail "bootstrap.sh rewrites gitops/apps manifests — root reverts such edits; commit the real values instead"
  else
    pass "bootstrap.sh does not rewrite the App-of-Apps manifests"
  fi
fi

echo
if [ "${FAILURES}" -gt 0 ]; then
  printf '\033[1;31mGitOps manifest verification FAILED (%s problem(s)).\033[0m\n' "${FAILURES}"
  exit 1
fi

printf '\033[1;32mGitOps manifests verified.\033[0m\n'
