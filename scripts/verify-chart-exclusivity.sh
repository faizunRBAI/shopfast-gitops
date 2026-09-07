#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Proves the core delivery requirement at CI time, on real rendered output:
#
#   "Never render a normal Deployment when Blue/Green or Canary is enabled."
#
# This is a TEST, not a lint. It renders the chart under each strategy and
# asserts on the object kinds actually produced. If someone later edits the
# template guards incorrectly, this fails the pipeline before anything ships.
#
# It also asserts the Rollouts ownership annotation on the Services (see the
# "managed-by-rollouts" checks below): that annotation is what stops Argo CD
# and Argo Rollouts fighting over the same field forever.
#
# ---------------------------------------------------------------------------
# RENDER FIXTURES -- why every required value is supplied here
# ---------------------------------------------------------------------------
# _validate.tpl fails the render unless FOUR values are present:
#     strategy   image.repository   image.tag   ingress.certificateArn
# The chart's own values.yaml deliberately leaves the environment-specific ones
# empty or as placeholders -- CI writes the real registry, tag and ACM ARN, and
# the Argo CD Application layers them on at sync time. So a BARE
# `helm template` of this chart can never succeed, by design.
#
# This script must therefore supply all four as TEST FIXTURES. They are dummy
# values chosen to be obviously fake; nothing here is a credential and nothing
# here is deployed. Omitting any one of them makes this script fail with a
# guard message that has nothing to do with strategy exclusivity -- which is
# exactly what happened when certificateArn was missing: the run died on
# "ingress.certificateArn is required", pointing at whichever template helm
# happened to render first, and the real subject of this test was never
# reached.
#
# NOTE: `helm lint` does NOT catch this. Lint downgrades a template `fail` to
# an informational line and still reports "0 chart(s) failed"; only
# `helm template` treats it as fatal. Do not rely on the lint step to prove the
# chart renders.
# ---------------------------------------------------------------------------
set -uo pipefail

CHART="application/helm/shopfast"
IMG_REPO="example.dkr.ecr.us-east-1.amazonaws.com/shopfast"
IMG_TAG="abc1234"
# Dummy ACM ARN -- correct SHAPE so the guard is satisfied, obviously not real.
CERT_ARN="arn:aws:acm:us-east-1:000000000000:certificate/00000000-0000-0000-0000-000000000000"

# Argo Rollouts stamps this on every Service it manages. The chart must declare
# it verbatim, or Argo CD self-heals it away and Rollouts re-adds it endlessly.
ROLLOUTS_ANN="argo-rollouts.argoproj.io/managed-by-rollouts: shopfast"

FAILED=0

pass() { printf '  \033[1;32m[ok]\033[0m %s\n' "$1"; }
fail() { printf '  \033[1;31m[FAIL]\033[0m %s\n' "$1"; FAILED=1; }

# Every required value in ONE place. A new guard in _validate.tpl means adding
# its value here, not weakening the guard.
render() {
  helm template shopfast "${CHART}" \
    --set "strategy=$1" \
    --set "image.repository=${IMG_REPO}" \
    --set "image.tag=${IMG_TAG}" \
    --set "ingress.certificateArn=${CERT_ARN}"
}

count_kind() {
  grep -cE "^kind: $1$" <<<"$2" || true
}

# Fixed-string occurrence count, for asserting on rendered field values.
count_matches() {
  grep -cF "$1" <<<"$2" || true
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

# --- render sanity ----------------------------------------------------------
# Assert the fixtures are COMPLETE before asserting anything about kinds. If a
# future guard is added and its fixture is not, this says so plainly instead of
# failing later with a message that looks unrelated to this test.
echo "==> render fixtures are complete"
if RENDER_ERR="$(render standard 2>&1 >/dev/null)"; then
  pass "chart renders with the supplied fixtures"
else
  fail "chart does not render with the supplied fixtures -- add the missing value to render()"
  printf '       %s\n' "${RENDER_ERR}" >&2
fi

# --- standard ---------------------------------------------------------------
echo "==> strategy=standard"
OUT="$(render standard)" || { echo "render failed" >&2; exit 1; }
expect_count "Deployment rendered"     "$(count_kind Deployment "$OUT")"       1
expect_count "Rollout NOT rendered"    "$(count_kind Rollout "$OUT")"          0
expect_count "AnalysisTemplate absent" "$(count_kind AnalysisTemplate "$OUT")" 0
expect_count "Service rendered"        "$(count_kind Service "$OUT")"          1
# No Rollout exists under this strategy, so nothing stamps the Service and
# claiming Rollouts ownership would be false.
expect_count "Rollouts annotation absent" "$(count_matches "${ROLLOUTS_ANN}" "$OUT")" 0

# --- bluegreen --------------------------------------------------------------
echo "==> strategy=bluegreen"
OUT="$(render bluegreen)" || { echo "render failed" >&2; exit 1; }
expect_count    "Deployment NOT rendered" "$(count_kind Deployment "$OUT")" 0
expect_count    "Rollout rendered"        "$(count_kind Rollout "$OUT")"    1
expect_contains "blueGreen strategy block present" "$OUT" "blueGreen:"
expect_contains "previewService configured"        "$OUT" "previewService:"
expect_count    "active + preview Services rendered" "$(count_kind Service "$OUT")" 2
# Both Services carry it, and the value is the ROLLOUT name on both -- the
# preview Service is shopfast-preview but the annotation still reads shopfast.
expect_count    "Rollouts annotation on both Services" \
                "$(count_matches "${ROLLOUTS_ANN}" "$OUT")" 2

# --- canary -----------------------------------------------------------------
echo "==> strategy=canary"
OUT="$(render canary)" || { echo "render failed" >&2; exit 1; }
expect_count    "Deployment NOT rendered" "$(count_kind Deployment "$OUT")" 0
expect_count    "Rollout rendered"        "$(count_kind Rollout "$OUT")"    1
expect_contains "canary strategy block present" "$OUT" "canary:"
expect_contains "weighted canary steps present" "$OUT" "setWeight:"
expect_count    "active + preview Services rendered" "$(count_kind Service "$OUT")" 2
expect_count    "Rollouts annotation on both Services" \
                "$(count_matches "${ROLLOUTS_ANN}" "$OUT")" 2

# --- scrape label contract --------------------------------------------------
# The ServiceScrape must publish the pod-template hash under its OWN name.
# A relabel writing targetLabel: version overwrites the Git SHA the app already
# exposes as a Micrometer common tag; the scraper renames the displaced value
# to exported_version and NOTHING ERRORS -- dashboards then key on an opaque
# ReplicaSet hash. Observed live. This asserts the contract holds.
echo "==> scrape label contract"
OUT="$(render bluegreen)" || { echo "render failed" >&2; exit 1; }
expect_contains "scrape publishes pod_hash"        "$OUT" "targetLabel: pod_hash"
expect_contains "scrape publishes strategy"        "$OUT" "targetLabel: strategy"
expect_count    "scrape does NOT clobber version" \
                "$(count_matches "targetLabel: version" "$OUT")" 0
# Service discovery converts every non-alphanumeric character to an underscore,
# so the relabel SOURCE must be underscored. Hyphens match nothing and emit an
# empty label WITHOUT erroring.
expect_contains "relabel source is underscored" \
                "$OUT" "__meta_kubernetes_pod_label_rollouts_pod_template_hash"
expect_count    "no hyphenated relabel source" \
                "$(count_matches "__meta_kubernetes_pod_label_rollouts-pod-template-hash" "$OUT")" 0

# --- guards -----------------------------------------------------------------
# These render DELIBERATELY BAD input and assert the chart refuses it. Every
# OTHER required value is still supplied, so a failure here proves the guard
# under test fired -- not that some unrelated value was missing.
echo "==> guard: mutable tag must be refused"
if helm template shopfast "${CHART}" --set strategy=standard \
     --set "image.repository=${IMG_REPO}" --set image.tag=latest \
     --set "ingress.certificateArn=${CERT_ARN}" >/dev/null 2>&1; then
  fail 'chart accepted the mutable tag "latest"'
else
  pass 'chart refused the mutable tag "latest"'
fi

echo "==> guard: unknown strategy must be refused"
if helm template shopfast "${CHART}" --set strategy=bogus \
     --set "image.repository=${IMG_REPO}" --set "image.tag=${IMG_TAG}" \
     --set "ingress.certificateArn=${CERT_ARN}" >/dev/null 2>&1; then
  fail "chart accepted an invalid strategy"
else
  pass "chart refused an invalid strategy"
fi

# The guard that broke this very script. Assert it fires, so the value can
# never be quietly dropped from the chart again.
echo "==> guard: ALB ingress without a certificate must be refused"
if helm template shopfast "${CHART}" --set strategy=standard \
     --set "image.repository=${IMG_REPO}" --set "image.tag=${IMG_TAG}" \
     --set "ingress.certificateArn=" >/dev/null 2>&1; then
  fail "chart accepted an ALB ingress with no certificate"
else
  pass "chart refused an ALB ingress with no certificate"
fi

echo
if [ "${FAILED}" -eq 0 ]; then
  echo "Chart strategy exclusivity verified."
  exit 0
fi
echo "Chart strategy exclusivity VIOLATED." >&2
exit 1
