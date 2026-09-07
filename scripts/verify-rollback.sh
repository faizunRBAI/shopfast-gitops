#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Rollback self-test — runs in the `security` stage, offline.
#
# WHY THIS EXISTS
#   A rollback path is only trustworthy if its REFUSALS work. Those refusals are
#   the difference between "restore the last good version" and "replace a
#   degraded service with an outage". They are cheap to assert and expensive to
#   discover broken, because you discover it during an incident.
#
#   The brief states "do not use `latest` as the rollback version". This turns
#   that from a claim into a tested property.
#
# No cluster, no AWS, no network: ECR_REPOSITORY is left unset so the registry
# existence check is skipped, and git history is read from a scratch repo built
# here. Safe to run anywhere.
# ---------------------------------------------------------------------------
set -uo pipefail

FAILURES=0
fail() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; FAILURES=$((FAILURES + 1)) || true; }
pass() { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }

RESOLVE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/rollback-resolve.sh"

echo "=== Rollback refusal verification ==="

[ -f "${RESOLVE}" ] || { fail "missing ${RESOLVE}"; exit 1; }

WORK="$(mktemp -d)"
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT

# --- build a scratch repo with a two-deploy history --------------------------
mkdir -p "${WORK}/gitops/applications/shopfast"
VALUES_REL="gitops/applications/shopfast/values.yaml"
VALUES_ABS="${WORK}/${VALUES_REL}"

write_values() {
  cat > "${VALUES_ABS}" <<EOF
strategy: bluegreen
image:
  repository: example.dkr.ecr.us-east-1.amazonaws.com/shopfast
  tag: "$1"
  pullPolicy: Always
service:
  port: 80
  # a decoy 'tag:' under a different block — the resolver must not read this
  tag: "decoy"
EOF
}

(
  cd "${WORK}"
  git init -q .
  git config user.email t@example.com
  git config user.name test
  write_values "aaaaaaa"
  git add -A && git commit -qm "ci: deploy shopfast aaaaaaa"
  write_values "bbbbbbb"
  git add -A && git commit -qm "ci: deploy shopfast bbbbbbb"
)

run_resolve() {
  # $1 = CURRENT_TAG, $2 = TARGET_TAG (may be empty)
  ( cd "${WORK}" && \
    VALUES_FILE="${VALUES_REL}" CURRENT_TAG="$1" TARGET_TAG="$2" \
    ECR_REPOSITORY="" GITHUB_OUTPUT="" GITHUB_STEP_SUMMARY="" \
    bash "${RESOLVE}" 2>&1 )
}

# --- 1. the happy path: find the previous deployed tag ----------------------
out="$(run_resolve "bbbbbbb" "")"; rc=$?
if [ "${rc}" -eq 0 ] && printf '%s' "${out}" | grep -q 'ROLLBACK TARGET: aaaaaaa'; then
  pass "resolves the previous deployed tag (bbbbbbb -> aaaaaaa)"
else
  fail "did not resolve the previous tag; rc=${rc} output: ${out}"
fi

# --- 2. it must not read a 'tag:' from an unrelated block -------------------
if printf '%s' "${out}" | grep -q 'decoy'; then
  fail "resolver read a 'tag:' key from outside the image block"
else
  pass "ignores 'tag:' keys outside the image block"
fi

# --- 3. 'latest' must be refused --------------------------------------------
out="$(run_resolve "bbbbbbb" "latest")"; rc=$?
if [ "${rc}" -ne 0 ] && printf '%s' "${out}" | grep -qi 'mutable tag'; then
  pass "refuses 'latest' as a rollback target"
else
  fail "accepted 'latest' as a rollback target; rc=${rc} output: ${out}"
fi

# --- 4. the bootstrap placeholder must be refused ---------------------------
out="$(run_resolve "bbbbbbb" "bootstrap")"; rc=$?
if [ "${rc}" -ne 0 ]; then
  pass "refuses the 'bootstrap' placeholder seed"
else
  fail "accepted the bootstrap placeholder as a rollback target"
fi

# --- 5. a no-op rollback must be refused ------------------------------------
out="$(run_resolve "bbbbbbb" "bbbbbbb")"; rc=$?
if [ "${rc}" -ne 0 ] && printf '%s' "${out}" | grep -qi 'Nothing to do'; then
  pass "refuses a rollback to the already-running tag"
else
  fail "accepted a no-op rollback; rc=${rc} output: ${out}"
fi

# --- 6. no previous version at all must be refused, not guessed -------------
SOLO="$(mktemp -d)"
mkdir -p "${SOLO}/gitops/applications/shopfast"
(
  cd "${SOLO}"
  git init -q .
  git config user.email t@example.com
  git config user.name test
  printf 'image:\n  tag: "onlyone"\n' > "${VALUES_REL}"
  git add -A && git commit -qm "ci: deploy shopfast onlyone"
)
out="$( cd "${SOLO}" && VALUES_FILE="${VALUES_REL}" CURRENT_TAG="onlyone" \
        TARGET_TAG="" ECR_REPOSITORY="" GITHUB_OUTPUT="" GITHUB_STEP_SUMMARY="" \
        bash "${RESOLVE}" 2>&1 )"; rc=$?
rm -rf "${SOLO}"
if [ "${rc}" -ne 0 ]; then
  pass "refuses when there is no previous version to roll back to"
else
  fail "invented a rollback target when history had only one version"
fi

# --- 7. the rollback path must never patch the Application spec -------------
# Comments are stripped first: these scripts document the second-writer bug at
# length, and a guard that trips over its own documentation is a broken guard.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for f in "${SCRIPT_DIR}"/rollback*.sh "${SCRIPT_DIR}"/argocd-sync-wait.sh; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  if sed -E 's/#.*$//' "$f" \
       | grep -qE '(argocd[[:space:]]+app[[:space:]]+set|kubectl[[:space:]].*patch[[:space:]]+application)'; then
    fail "${name}: patches the Argo CD Application spec — root reconciles it from git with selfHeal on, so this is a second writer and will loop forever. Write the tag to git instead."
  else
    pass "${name}: does not patch the Application spec"
  fi
done

echo
if [ "${FAILURES}" -gt 0 ]; then
  printf '\033[1;31mRollback verification FAILED (%s problem(s)).\033[0m\n' "${FAILURES}"
  exit 1
fi

printf '\033[1;32mRollback path verified.\033[0m\n'
