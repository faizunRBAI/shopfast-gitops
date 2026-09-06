#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GitOps manifest guard — runs in the `security` stage, BEFORE any AWS
# resource is touched.
#
# WHY THIS EXISTS
#   The root App-of-Apps reconciles gitops/apps/children/*.yaml FROM GIT. Any
#   value injected into a live Application at bootstrap time is therefore
#   reverted on root's next sync, and the Application is left with whatever git
#   actually contains. When git contained an unresolved placeholder, the result
#   was:
#
#     status: "Failed to load target state: ... repository not found"
#
#   with the workload silently never created — a failure that only surfaced
#   minutes later, in Argo CD, long after CI had gone green.
#
#   These checks make that class of mistake fail in ~2 seconds instead.
#
# SCOPE: only the Application manifests under gitops/apps/ are inspected, and
# only their actual `repoURL:` values. Scripts and prose elsewhere under
# gitops/ legitimately mention placeholder names while explaining this bug, and
# a guard that trips over its own documentation is a broken guard.
# ---------------------------------------------------------------------------
set -uo pipefail

FAILURES=0
fail() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; FAILURES=$((FAILURES + 1)) || true; }
pass() { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }

APPS_DIR="gitops/apps"
ROOT_APP="${APPS_DIR}/root-app.yaml"
CHILDREN_DIR="${APPS_DIR}/children"

echo "=== GitOps manifest verification ==="

[ -f "${ROOT_APP}" ] || fail "missing ${ROOT_APP}"

# 1+2. Every Application's repoURL must be a real, resolvable URL. This single
#      check subsumes "no placeholders": a placeholder is simply not a URL.
for f in "${ROOT_APP}" "${CHILDREN_DIR}"/*.yaml; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"

  # Strip comments, then read the value of the first real repoURL key.
  url="$(grep -E '^[[:space:]]*repoURL:' "$f" \
         | head -n1 \
         | sed -E 's/^[[:space:]]*repoURL:[[:space:]]*//; s/[[:space:]]*$//; s/^["'"'"']//; s/["'"'"']$//')"

  if [ -z "${url}" ]; then
    fail "${name}: no repoURL found"
    continue
  fi

  case "${url}" in
    https://*|http://*|oci://*|git@*)
      pass "${name}: repoURL resolves (${url})"
      ;;
    *)
      fail "${name}: repoURL is not a URL: '${url}' — the root app applies this value verbatim, so it must be committed in full"
      ;;
  esac
done

# 3. Child Applications must not carry apply-time helm parameters. Anything the
#    chart needs belongs in a values file git owns, or root will fight whoever
#    injects it.
for f in "${CHILDREN_DIR}"/*.yaml; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  if grep -qE '^[[:space:]]+parameters:' "$f"; then
    fail "${name}: declares helm parameters; put environment-specific values in a committed values file instead"
  else
    pass "${name}: no apply-time helm parameters"
  fi
done

# 4. The bootstrap script must not rewrite the App-of-Apps manifests. Only an
#    actual sed COMMAND counts — comments explaining why this is forbidden do
#    not. Match a sed invocation at a command position that targets gitops/apps.
BOOTSTRAP="gitops/bootstrap/bootstrap.sh"
if [ -f "${BOOTSTRAP}" ]; then
  if grep -nE '^[[:space:]]*[^#]*(^|[|;&[:space:]])sed[[:space:]][^|;&]*gitops/apps' "${BOOTSTRAP}" >/dev/null 2>&1; then
    grep -nE '^[[:space:]]*[^#]*(^|[|;&[:space:]])sed[[:space:]][^|;&]*gitops/apps' "${BOOTSTRAP}" || true
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
