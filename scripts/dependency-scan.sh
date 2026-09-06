#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# OWASP dependency-check for the ShopFast application.
#
# Fails the build on any dependency with CVSS >= 9 (critical).
#
# The NVD credential is OPTIONAL and is consumed straight from the environment
# by the maven plugin property below. It is never printed, never written to a
# file, and never echoed into the log.
# ---------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")/../application"

MVN_ARGS=(
  -B -ntp
  org.owasp:dependency-check-maven:10.0.4:check
  -DfailBuildOnCVSS=9
  -DassemblyAnalyzerEnabled=false
  -DretireJsAnalyzerEnabled=false
)

if [ -n "${NVD_API_KEY:-}" ]; then
  echo "NVD credential present — using the authenticated NVD feed."
  MVN_ARGS+=("-DnvdApiKey=${NVD_API_KEY}")
else
  echo "No NVD credential configured — using the unauthenticated feed."
  echo "This is slower and may be rate-limited by NVD. Setting the NVD_API_KEY"
  echo "repository secret speeds it up: https://nvd.nist.gov/developers/request-an-api-key"
fi

echo "Running OWASP dependency-check (build fails on CVSS >= 9)…"
mvn "${MVN_ARGS[@]}"
