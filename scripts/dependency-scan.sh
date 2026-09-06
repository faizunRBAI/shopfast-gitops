#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# OWASP dependency-check for the ShopFast application.
#
# Fails the build on any dependency with CVSS >= 9 (critical).
#
# The plugin VERSION and its configuration (threshold, disabled analyzers,
# suppression file) live in application/pom.xml so that CI and a local run
# behave identically. This script only selects the goal and supplies the
# optional NVD credential.
#
# The NVD credential is consumed straight from the environment. It is never
# printed, written to a file, or echoed into the log.
# ---------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")/../application"

MVN_ARGS=(-B -ntp org.owasp:dependency-check-maven:check)

if [ -n "${NVD_API_KEY:-}" ]; then
  echo "NVD credential present — using the authenticated NVD feed."
  MVN_ARGS+=("-DnvdApiKey=${NVD_API_KEY}")
else
  echo "No NVD credential configured — using the unauthenticated feed."
  echo "This is slower and may be rate-limited by NVD. Setting the NVD_API_KEY"
  echo "repository secret speeds it up: https://nvd.nist.gov/developers/request-an-api-key"
fi

echo "Running OWASP dependency-check (build fails on CVSS >= 9)…"
echo "A failure here means a REAL vulnerable dependency — upgrade it."
echo "Do not add suppressions to turn this green; see application/owasp-suppressions.xml."
mvn "${MVN_ARGS[@]}"
