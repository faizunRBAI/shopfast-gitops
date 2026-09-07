#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# OWASP dependency-check for the ShopFast application.
#
# WHERE THIS RUNS: the `security-deps` workflow (.github/workflows/
# security-deps.yml), triggered on demand — NOT in the deploy pipeline.
# dependency-check must download the entire ~387,000-record NVD corpus before it
# can inspect a single jar, which made every deployment gated on nvd.nist.gov's
# throughput. See docs/DEPENDENCY-SCANNING.md for the measurements and README
# section 9.2 for the decision. The scan itself is UNCHANGED by that move.
#
# REPORTING MODE (accepted risk — decision recorded 2026-09-06).
# The threshold lives in application/pom.xml as security.failBuildOnCVSS and is
# currently 11, i.e. above the maximum CVSS score, so findings do not fail the
# build. The scan still produces its full report.
#
# Reporting mode is only worth anything if somebody SEES the findings, so this
# script prints a critical/high summary to the job log after the scan and the
# workflow uploads the HTML + JSON reports as build artifacts.
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

echo "Running OWASP dependency-check…"
echo "NOTE: on a cold cache this downloads the full NVD feed (~387k records)."
echo "Feed throughput has been measured between ~2,600 and ~97,000 records/min,"
echo "so a first run can take from minutes to hours. Subsequent runs restore the"
echo "cached database and fetch only the delta. See docs/DEPENDENCY-SCANNING.md."
mvn "${MVN_ARGS[@]}"

# --- Surface the findings ---------------------------------------------------
REPORT="target/dependency-check-report.json"

if [ ! -f "${REPORT}" ]; then
  echo "::warning::dependency-check produced no JSON report; cannot summarise findings."
  exit 0
fi

echo "::group::Dependency vulnerability summary"
python3 - "${REPORT}" <<'PY'
import json, sys
from collections import defaultdict

with open(sys.argv[1]) as fh:
    report = json.load(fh)

buckets = defaultdict(list)          # severity -> [(dependency, cve, score)]
for dep in report.get("dependencies", []):
    name = dep.get("fileName", "unknown")
    for vuln in dep.get("vulnerabilities", []):
        cve = vuln.get("name", "?")
        score = None
        for key in ("cvssv3", "cvssv4"):
            block = vuln.get(key) or {}
            score = block.get("baseScore") or block.get("cvssData", {}).get("baseScore")
            if score is not None:
                break
        if score is None:
            score = vuln.get("cvssv2", {}).get("score", 0.0)
        score = float(score or 0.0)

        if score >= 9.0:
            sev = "CRITICAL"
        elif score >= 7.0:
            sev = "HIGH"
        else:
            continue                  # medium/low: in the HTML report only
        buckets[sev].append((name, cve, score))

if not buckets:
    print("No HIGH or CRITICAL findings.")
    sys.exit(0)

for sev in ("CRITICAL", "HIGH"):
    items = buckets.get(sev, [])
    if not items:
        continue
    print(f"\n{sev}: {len(items)} finding(s)")
    by_dep = defaultdict(list)
    for name, cve, score in items:
        by_dep[name].append(f"{cve}({score})")
    for name in sorted(by_dep):
        print(f"  {name}")
        print(f"    {', '.join(sorted(by_dep[name]))}")

total = sum(len(v) for v in buckets.values())
print(f"\n{total} HIGH/CRITICAL finding(s). Full detail: dependency-check-report.html")
print("These do NOT fail the build (reporting mode — see security.failBuildOnCVSS")
print("in application/pom.xml for the accepted-risk rationale and revisit condition).")
PY
echo "::endgroup::"

# A visible annotation on the run summary, so reporting mode never becomes
# silent mode.
CRIT_COUNT="$(python3 - "${REPORT}" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    report = json.load(fh)
n = 0
for dep in report.get("dependencies", []):
    for vuln in dep.get("vulnerabilities", []):
        score = None
        for key in ("cvssv3", "cvssv4"):
            block = vuln.get(key) or {}
            score = block.get("baseScore") or block.get("cvssData", {}).get("baseScore")
            if score is not None:
                break
        if score is None:
            score = vuln.get("cvssv2", {}).get("score", 0.0)
        if float(score or 0.0) >= 9.0:
            n += 1
print(n)
PY
)"

if [ "${CRIT_COUNT}" -gt 0 ]; then
  echo "::warning title=Accepted security risk::${CRIT_COUNT} CRITICAL (CVSS>=9) dependency finding(s) present. Reporting mode is enabled, so these do not block the build. See the dependency-check artifact and application/pom.xml."
fi
