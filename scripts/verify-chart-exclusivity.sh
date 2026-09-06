#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Proves the core delivery requirement at CI time, on real rendered output:
#
#   "Never render a normal Deployment when Blue/Green or Canary is enabled."
#
# This is a TEST, not a lint. It renders the chart under each strategy and
# asserts on the object kinds actually produced. If someone later edits the
# template guards incorrectly, this fails the pipeline before anything ships.
# ---------------------------------------------------------------------------
set -uo pipefail

CHART="application/helm/shopfast"
IMG_REPO="example.dkr.ecr.us-east-1.amazonaws.com/shopfast"
IMG_TAG="abc1234"

FAILED=0

pass() { printf '  \033[1;32m[ok]\033[0m %s\n' "$1"; }
fail() { printf '  \033[1;31m[FAIL]\033[0m %s\n' "$1"; FAILED=1; }

render() {
  helm template shopfast "${CHART}" \
    --set "strategy=$1" \
    --set "image.repository=${IMG_REPO}" \
    --set "image.tag=${IMG_TAG}"
}

count_kind() {
  grep -cE "^kind: $1$" <<<"$2" || true
}

expect_count() {
  local label="$1" actual="$2" want="$3"
  if [ "${actual}" = "${want}" ]; then
    pass "${label} (expected ${want}, got ${actual})"
  else
    fail "${label} (expected ${want}, got ${actual})"
  fi
}

expect_contains() {
  local label="$1" haystack="$2" needle="$3"
  if grep -q "${needle}" <<<"${haystack}"; then
    pass "${label}"
  else
    fail "${label}"
  fi
}

# --- standard ---------------------------------------------------------------
echo "==> strategy=standard"
OUT="$(render standard)" || { echo "render failed" >&2; exit 1; }
expect_count "Deployment rendered"     "$(count_kind Deployment "$OUT")"       1
expect_count "Rollout NOT rendered"    "$(count_kind Rollout "$OUT")"          0
expect_count "AnalysisTemplate absent" "$(count_kind AnalysisTemplate "$OUT")" 0

# --- bluegreen --------------------------------------------------------------
echo "==> strategy=bluegreen"
OUT="$(render bluegreen)" || { echo "render failed" >&2; exit 1; }
expect_count    "Deployment NOT rendered" "$(count_kind Deployment "$OUT")" 0
expect_count    "Rollout rendered"        "$(count_kind Rollout "$OUT")"    1
expect_contains "blueGreen strategy block present" "$OUT" "blueGreen:"
expect_contains "previewService configured"        "$OUT" "previewService:"

# --- canary -----------------------------------------------------------------
echo "==> strategy=canary"
OUT="$(render canary)" || { echo "render failed" >&2; exit 1; }
expect_count    "Deployment NOT rendered" "$(count_kind Deployment "$OUT")" 0
expect_count    "Rollout rendered"        "$(count_kind Rollout "$OUT")"    1
expect_contains "canary strategy block present" "$OUT" "canary:"
expect_contains "weighted canary steps present" "$OUT" "setWeight:"

# --- guards -----------------------------------------------------------------
echo "==> guard: mutable tag must be refused"
if helm template shopfast "${CHART}" --set strategy=standard \
     --set "image.repository=${IMG_REPO}" --set image.tag=latest >/dev/null 2>&1; then
  fail 'chart accepted the mutable tag "latest"'
else
  pass 'chart refused the mutable tag "latest"'
fi

echo "==> guard: unknown strategy must be refused"
if helm template shopfast "${CHART}" --set strategy=bogus \
     --set "image.repository=${IMG_REPO}" --set "image.tag=${IMG_TAG}" >/dev/null 2>&1; then
  fail "chart accepted an invalid strategy"
else
  pass "chart refused an invalid strategy"
fi

echo
if [ "${FAILED}" -eq 0 ]; then
  echo "Chart strategy exclusivity verified."
  exit 0
fi
echo "Chart strategy exclusivity VIOLATED." >&2
exit 1
