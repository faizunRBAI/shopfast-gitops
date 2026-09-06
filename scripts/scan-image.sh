#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Container image vulnerability scan (Trivy).
#
# Uses the Trivy CLI binary directly rather than aquasecurity/trivy-action.
#
# WHY NOT THE ACTION: trivy-action@v0.28.0 is a composite action that internally
# pins aquasecurity/setup-trivy@v0.2.1 — a tag that no longer exists upstream
# (the repo now starts at v0.2.6). GitHub resolves nested action references at
# pre-flight, so the job dies before any step runs, with an error naming a
# repository this project does not reference. Pinning the CLI removes that whole
# class of third-party breakage: one versioned binary, no nested dependencies.
#
# Reporting mode: this scan does NOT fail the build (matching the dependency
# scan decision recorded in application/pom.xml and README section 9). ECR
# scan-on-push is the enforcing control at the registry.
#
# Usage: scan-image.sh <image-ref>
# ---------------------------------------------------------------------------
set -euo pipefail

TRIVY_VERSION="0.74.0"
IMAGE="${1:?usage: scan-image.sh <image-ref>}"

echo "Installing Trivy ${TRIVY_VERSION}…"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

curl -fsSL \
  "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" \
  -o "${TMP}/trivy.tar.gz"

tar -xzf "${TMP}/trivy.tar.gz" -C "${TMP}" trivy
chmod +x "${TMP}/trivy"

"${TMP}/trivy" --version

echo "::group::Trivy scan — ${IMAGE}"
# --exit-code 0 keeps this reporting-only. --scanners vuln skips secret/config
# scanning, which would re-report the application dependencies already covered
# by the OWASP stage.
"${TMP}/trivy" image \
  --severity HIGH,CRITICAL \
  --scanners vuln \
  --exit-code 0 \
  --no-progress \
  --timeout 10m \
  "${IMAGE}"
echo "::endgroup::"

# Machine-readable copy for the build artifact.
"${TMP}/trivy" image \
  --severity HIGH,CRITICAL \
  --scanners vuln \
  --exit-code 0 \
  --no-progress \
  --timeout 10m \
  --format json \
  --output trivy-image-report.json \
  "${IMAGE}" || echo "::warning::Trivy JSON report generation failed (table output above still valid)"

# Surface a count so reporting mode stays visible on the run summary.
if [ -f trivy-image-report.json ]; then
  python3 - <<'PY'
import json
try:
    with open("trivy-image-report.json") as fh:
        data = json.load(fh)
except Exception as exc:                      # noqa: BLE001
    print(f"could not parse the Trivy report: {exc}")
    raise SystemExit(0)

counts = {"CRITICAL": 0, "HIGH": 0}
for result in data.get("Results") or []:
    for vuln in result.get("Vulnerabilities") or []:
        sev = vuln.get("Severity")
        if sev in counts:
            counts[sev] += 1

total = counts["CRITICAL"] + counts["HIGH"]
if total:
    print(f"::warning title=Image scan::Trivy found {counts['CRITICAL']} CRITICAL "
          f"and {counts['HIGH']} HIGH vulnerabilities in the image "
          f"(reporting mode — does not block the build).")
else:
    print("Trivy found no HIGH or CRITICAL vulnerabilities in the image.")
PY
fi
